param(
  [switch]$WhatIfOnly,
  [switch]$Force,
  [switch]$Json,
  [string]$ExpectedSourceHash = '',
  [string]$ExpectedPlanFingerprint = '',
  [ValidateSet('none','after_backup','after_swap','after_rebuild')][string]$FaultPoint = 'none'
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\memory-rewrite-transaction.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$memoryPath = Join-Path $memoryRoot 'sandglass.txt'
if (-not (Test-Path -LiteralPath $memoryPath -PathType Leaf)) { throw "Missing memory file: $memoryPath" }

function Write-CompactApplyResult([object]$Result) {
  if ($Json) {
    $Result | ConvertTo-Json -Depth 10
  } else {
    Write-Host "COMPACT_APPLY status=$($Result.status) removed=$($Result.removed) memory=$($Result.memoryPath) sourceHash=$($Result.sourceHash) plan=$($Result.planFingerprint)"
    if ($Result.PSObject.Properties['backupPath'] -and $Result.backupPath) { Write-Host "COMPACT_APPLY_BACKUP path=$($Result.backupPath)" }
    if ($Result.PSObject.Properties['receiptPath'] -and $Result.receiptPath) { Write-Host "COMPACT_APPLY_RECEIPT path=$($Result.receiptPath)" }
    if ($Result.PSObject.Properties['error'] -and $Result.error) { Write-Host "COMPACT_APPLY_ERROR $($Result.error)" }
  }
}

$plan = Get-SuperBrainMemoryDedupPlan @(Get-Content -LiteralPath $memoryPath -Encoding UTF8)
$report = New-SuperBrainMemoryDedupReport $memoryPath $plan 20 160
$baseResult = [ordered]@{
  schema = 'super-brain.memory-compact-apply.v2'
  memoryPath = $memoryPath
  sourceHash = $report.sourceHash
  planFingerprint = $report.planFingerprint
  replacementHash = $report.replacementHash
  removed = [int]$plan.duplicateCount
}

if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceHash) -and -not [string]::Equals($ExpectedSourceHash,$report.sourceHash,[StringComparison]::OrdinalIgnoreCase)) {
  $result = [pscustomobject]($baseResult + [ordered]@{ ok=$false; status='stale_source'; error="COMPACT_APPLY_EXPECTED_SOURCE_HASH_MISMATCH expected=$ExpectedSourceHash actual=$($report.sourceHash)" })
  Write-CompactApplyResult $result
  exit 1
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and -not [string]::Equals($ExpectedPlanFingerprint,$report.planFingerprint,[StringComparison]::OrdinalIgnoreCase)) {
  $result = [pscustomobject]($baseResult + [ordered]@{ ok=$false; status='stale_plan'; error="COMPACT_APPLY_EXPECTED_PLAN_FINGERPRINT_MISMATCH expected=$ExpectedPlanFingerprint actual=$($report.planFingerprint)" })
  Write-CompactApplyResult $result
  exit 1
}

if ($WhatIfOnly) {
  $result = [pscustomobject]($baseResult + [ordered]@{ ok=$true; status='dry_run'; changed=$false; guard='No memory or index was changed. Pass sourceHash and planFingerprint from compact-report for a bounded confirmed rewrite.' })
  Write-CompactApplyResult $result
  exit 0
}
if ($plan.duplicateCount -eq 0) {
  $result = [pscustomobject]($baseResult + [ordered]@{ ok=$true; status='no_change'; changed=$false; guard='No exact duplicate exists after timestamp/source normalization.' })
  Write-CompactApplyResult $result
  exit 0
}
if (-not $Force) {
  $result = [pscustomobject]($baseResult + [ordered]@{ ok=$true; status='confirmation_required'; changed=$false; guard='Use -Force only after reviewing compact-report. The apply transaction rechecks the source hash while holding the memory lock.' })
  Write-CompactApplyResult $result
  exit 0
}

try {
  $transaction = Invoke-SuperBrainMemoryRewriteTransaction -MemoryRoot $memoryRoot -MemoryPath $memoryPath -ReplacementText ([string]$plan.replacementText) -ExpectedSourceHash $report.sourceHash -LineMap $plan.lineMap -TransactionKind 'compact' -FaultPoint $FaultPoint
  $result = [pscustomobject]($baseResult + [ordered]@{
    ok = [bool]$transaction.ok
    status = 'committed'
    changed = [bool]$transaction.changed
    backupPath = [string]$transaction.backupPath
    receiptPath = [string]$transaction.receiptPath
    transactionId = [string]$transaction.transactionId
    indexRebuild = $transaction.indexRebuild
  })
  Write-CompactApplyResult $result
  exit 0
} catch {
  $result = [pscustomobject]($baseResult + [ordered]@{ ok=$false; status='failed'; changed=$false; error=$_.Exception.Message })
  Write-CompactApplyResult $result
  exit 1
}
