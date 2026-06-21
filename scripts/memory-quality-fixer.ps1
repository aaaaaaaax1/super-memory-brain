param(
  [switch]$Json,
  [switch]$ShowDetails
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$memoryPath = Join-Path $memoryRoot 'sandglass.txt'
$decisionPath = Join-Path $memoryRoot 'decision_particles.txt'
$policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$actions = @()

if (Test-Path $memoryPath) {
  $lineNumber = 0
  foreach ($line in Get-Content -LiteralPath $memoryPath -Encoding UTF8) {
    $lineNumber += 1
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $hasTag = $false
    foreach ($tag in @($policy.requiredTags)) {
      if ($line.Contains($tag)) { $hasTag = $true; break }
    }
    if (-not $hasTag) {
      $actions += [pscustomobject]@{ type='untagged'; file=$memoryPath; line=$lineNumber; action='Add one required tag or migrate to structured workspace note'; preview=($line.Substring(0, [Math]::Min(160, $line.Length))) }
    }
    if ($line.Length -gt [int]$policy.maxMemoryChars) {
      $suggestedSummary = $line
      foreach ($marker in @(' | evidence=', ' | consequences=', ' | alternatives=', ' | source=')) {
        $markerIndex = $suggestedSummary.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
        if ($markerIndex -gt 0) { $suggestedSummary = $suggestedSummary.Substring(0, $markerIndex); break }
      }
      if ($suggestedSummary.Length -gt 240) { $suggestedSummary = $suggestedSummary.Substring(0, 240) + '...' }
      $detail = [pscustomobject]@{
        currentChars = $line.Length
        maxChars = [int]$policy.maxMemoryChars
        overBy = ($line.Length - [int]$policy.maxMemoryChars)
        suggestedSummary = $suggestedSummary
        preserveTags = @([regex]::Matches($line, '\[[A-Z_]+\]') | ForEach-Object { $_.Value } | Select-Object -Unique)
        needsManualReview = $true
      }
      $action = [ordered]@{ type='too_long'; file=$memoryPath; line=$lineNumber; action="Compress below $($policy.maxMemoryChars) chars or move detail to workspace evidence"; preview=($line.Substring(0, [Math]::Min(160, $line.Length))) }
      if ($ShowDetails) { $action.detail = $detail }
      $actions += [pscustomobject]$action
    }
  }
}

if (Test-Path $decisionPath) {
  $lineNumber = 0
  foreach ($line in Get-Content -LiteralPath $decisionPath -Encoding UTF8) {
    $lineNumber += 1
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if (($line -split ' \| ').Count -lt 6) {
      $actions += [pscustomobject]@{ type='malformed_decision_particle'; file=$decisionPath; line=$lineNumber; action='Rewrite decision particle with timestamp, key, title, decision, evidence, and tags fields'; preview=($line.Substring(0, [Math]::Min(160, $line.Length))) }
    }
  }
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  mode = if ($ShowDetails) { 'WhatIfOnlyWithDetails' } else { 'WhatIfOnly' }
  actionCount = $actions.Count
  actions = @($actions)
  recommendation = if ($actions.Count -eq 0) { 'No memory quality cleanup actions suggested.' } else { 'Review suggested actions; this script does not modify memory.' }
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else {
  Write-Host "MEMORY_QUALITY_FIXER ok=True mode=$($result.mode) actions=$($actions.Count)"
  foreach ($action in @($actions | Select-Object -First 20)) {
    Write-Host "MEMORY_QUALITY_ACTION type=$($action.type) file=$($action.file) line=$($action.line) action=$($action.action)"
    if ($ShowDetails -and $action.PSObject.Properties['detail']) {
      Write-Host "MEMORY_QUALITY_DETAIL type=$($action.type) line=$($action.line) chars=$($action.detail.currentChars) max=$($action.detail.maxChars) overBy=$($action.detail.overBy) preserveTags=$(@($action.detail.preserveTags) -join ',')"
    }
  }
}
exit 0
