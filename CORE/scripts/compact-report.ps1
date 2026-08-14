param(
  [switch]$Json,
  [ValidateRange(1,200)][int]$MaxDuplicateGroups = 20,
  [ValidateRange(32,4096)][int]$MaxSampleChars = 160,
  [switch]$IncludeSamples
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\memory-rewrite-transaction.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryPath = Join-Path (Get-SuperBrainActiveMemoryRoot $Root) 'sandglass.txt'
if (-not (Test-Path -LiteralPath $memoryPath -PathType Leaf)) { throw "Missing memory file: $memoryPath" }

$plan = Get-SuperBrainMemoryDedupPlan @(Get-Content -LiteralPath $memoryPath -Encoding UTF8)
$report = New-SuperBrainMemoryDedupReport $memoryPath $plan $MaxDuplicateGroups $MaxSampleChars -IncludeSamples:$IncludeSamples

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "COMPACT_REPORT schema=$($report.schema) memory=$($report.memoryPath) sourceHash=$($report.sourceHash) totalLines=$($report.totalLines) keptLines=$($report.keptLines) duplicateCount=$($report.duplicateCount) groups=$($report.duplicateGroupCount) plan=$($report.planFingerprint)"
  foreach ($group in @($report.duplicateGroups)) {
    Write-Host "DUP_GROUP fingerprint=$($group.fingerprint) firstLine=$($group.firstLine) replacementLine=$($group.replacementLine) duplicateCount=$($group.duplicateCount) duplicateLines=$(@($group.duplicateLines) -join ',') truncated=$($group.duplicateLinesTruncated)"
    if ($IncludeSamples -and -not [string]::IsNullOrWhiteSpace([string]$group.sample)) { Write-Host "DUP_SAMPLE fingerprint=$($group.fingerprint) text=$($group.sample)" }
  }
  if ($report.duplicateGroupsTruncated) { Write-Host "DUP_GROUPS_TRUNCATED visible=$($report.duplicateGroups.Count) total=$($report.duplicateGroupCount)" }
  Write-Host "COMPACT_REPORT_PRIVACY samplesIncluded=$($report.samplesIncluded)"
}

exit 0
