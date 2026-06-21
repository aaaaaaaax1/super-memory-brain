param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$memoryPath = Join-Path $memoryRoot 'sandglass.txt'
$graphPath = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'graph.jsonl'
$decisionPath = Join-Path $memoryRoot 'decision_particles.txt'
$policyPath = Join-Path $Root 'memory-policy.json'

$policy = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8 | ConvertFrom-Json
$lines = @()
if (Test-Path $memoryPath) {
  $lines = @(Get-Content -LiteralPath $memoryPath -Encoding UTF8)
}
$nonEmpty = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

$tagCounts = [ordered]@{}
foreach ($tag in @($policy.requiredTags)) {
  $tagCounts[$tag] = @($nonEmpty | Where-Object { $_.Contains($tag) }).Count
}

$untagged = 0
foreach ($line in $nonEmpty) {
  $hasTag = $false
  foreach ($tag in @($policy.requiredTags)) {
    if ($line.Contains($tag)) { $hasTag = $true; break }
  }
  if (-not $hasTag) { $untagged += 1 }
}

$tooLong = @($nonEmpty | Where-Object { $_.Length -gt [int]$policy.maxMemoryChars }).Count
$privateHits = 0
foreach ($line in $nonEmpty) {
  $lower = $line.ToLowerInvariant()
  foreach ($pattern in @($policy.privatePatterns)) {
    if ($lower.Contains($pattern.ToLowerInvariant())) {
      if ($pattern -eq 'token' -and $line -match 'token cache buckets|token bucket|cache bucket|usage reports|cache token|token cost|token usage|context tokens|fragmentation|responses route|cache metric|cache work|warm.*gap|baseline.*cache') { continue }
      $privateHits += 1
      break
    }
  }
}

$seen = @{}
$duplicates = 0
foreach ($line in $nonEmpty) {
  $key = $line -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| [^|]+ \| ', ''
  if ($seen.ContainsKey($key)) {
    $duplicates += 1
  } else {
    $seen[$key] = $true
  }
}

$decisionMemoryCount = @($nonEmpty | Where-Object { $_.Contains('[DECISION]') }).Count
$adrMemoryCount = @($nonEmpty | Where-Object { $_.Contains('[ADR]') }).Count
$layerCounts = [ordered]@{}
foreach ($layerName in @($policy.layers.allowed)) {
  $layerTag = [string]$policy.layers.tagMap.$layerName
  $layerCounts[$layerName] = @($nonEmpty | Where-Object { $_.Contains($layerTag) }).Count
}
$summaryCount = @($nonEmpty | Where-Object { $_.Contains('[SUMMARY]') }).Count
$negativeFeedbackCount = @($nonEmpty | Where-Object { $_.Contains('[NEGATIVE_FEEDBACK]') }).Count
$expiresCount = 0
$expiredCount = 0
$invalidExpiryCount = 0
foreach ($line in $nonEmpty) {
  $matches = [regex]::Matches($line, 'expires=([^\s]+)')
  foreach ($match in $matches) {
    $expiresCount += 1
    try {
      if ([datetime]::Parse($match.Groups[1].Value) -lt (Get-Date).Date) { $expiredCount += 1 }
    } catch {
      $invalidExpiryCount += 1
    }
  }
}
$graphParseErrorCount = 0
$decisionGraph = @()
$adrGraph = @()
if (Test-Path $graphPath) {
  foreach ($line in @(Get-Content -LiteralPath $graphPath -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $node = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json
      $tags = [string]$node.tags
      $subject = [string]$node.subject
      if ($tags.Contains('[DECISION]') -or $subject.StartsWith('decision:')) {
        $decisionGraph += $node
      }
      if ($tags.Contains('[ADR]') -or ([string]$node.relation) -in @('has_title','has_status','has_context','has_consequence','has_owner','affects','has_alternative')) {
        $adrGraph += $node
      }
    } catch {
      $graphParseErrorCount += 1
    }
  }
}
$decisionCurrentConflictCount = @($decisionGraph |
  Where-Object { ([string]$_.tags).Contains('[CURRENT]') -and ([string]$_.relation) -eq 'decides' } |
  Group-Object subject |
  Where-Object { $_.Count -gt 1 }).Count

$adrSubjects = @($adrGraph | ForEach-Object { [string]$_.subject } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$adrStatusRows = @($adrGraph | Where-Object { ([string]$_.relation) -eq 'has_status' })
$adrCurrentCount = @($adrStatusRows | Where-Object { @($policy.adr.currentStatuses) -contains ([string]$_.object) }).Count
$adrSupersededCount = @($adrGraph | Where-Object { ([string]$_.relation) -eq 'superseded_by' -or ([string]$_.object) -eq 'superseded' }).Count

$decisionParticles = @()
if (Test-Path $decisionPath) {
  $decisionParticles = @(Get-Content -LiteralPath $decisionPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$malformedDecisionParticleCount = 0
foreach ($line in $decisionParticles) {
  if (($line -split ' \| ').Count -lt 6) { $malformedDecisionParticleCount += 1 }
}

$result = [pscustomobject]@{
  ok = (Test-Path $memoryPath)
  memory = $memoryPath
  totalLines = $lines.Count
  nonEmptyLines = $nonEmpty.Count
  duplicateCount = $duplicates
  untaggedCount = $untagged
  tooLongCount = $tooLong
  privatePatternHitCount = $privateHits
  maxMemoryChars = [int]$policy.maxMemoryChars
  decisionMemoryCount = $decisionMemoryCount
  adrMemoryCount = $adrMemoryCount
  decisionGraphCount = $decisionGraph.Count
  adrGraphCount = $adrGraph.Count
  adrSubjectCount = $adrSubjects.Count
  adrCurrentCount = $adrCurrentCount
  adrSupersededCount = $adrSupersededCount
  decisionParticleCount = $decisionParticles.Count
  malformedDecisionParticleCount = $malformedDecisionParticleCount
  graphParseErrorCount = $graphParseErrorCount
  decisionCurrentConflictCount = $decisionCurrentConflictCount
  layerCounts = $layerCounts
  summaryCount = $summaryCount
  negativeFeedbackCount = $negativeFeedbackCount
  expiresCount = $expiresCount
  expiredCount = $expiredCount
  invalidExpiryCount = $invalidExpiryCount
  tagCounts = $tagCounts
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "MEMORY_HEALTH ok=$($result.ok) totalLines=$($result.totalLines) nonEmpty=$($result.nonEmptyLines) duplicates=$($result.duplicateCount) untagged=$($result.untaggedCount) tooLong=$($result.tooLongCount) privateHits=$($result.privatePatternHitCount) decisionMemory=$($result.decisionMemoryCount) adrMemory=$($result.adrMemoryCount) decisionGraph=$($result.decisionGraphCount) adrGraph=$($result.adrGraphCount) adrCurrent=$($result.adrCurrentCount) adrSuperseded=$($result.adrSupersededCount) particles=$($result.decisionParticleCount) malformedParticles=$($result.malformedDecisionParticleCount) graphParseErrors=$($result.graphParseErrorCount) decisionCurrentConflicts=$($result.decisionCurrentConflictCount) summaries=$($result.summaryCount) negativeFeedback=$($result.negativeFeedbackCount) expires=$($result.expiresCount) expired=$($result.expiredCount) invalidExpiry=$($result.invalidExpiryCount)"
  foreach ($layer in $layerCounts.Keys) {
    Write-Host "LAYER $layer count=$($layerCounts[$layer])"
  }
  foreach ($tag in $tagCounts.Keys) {
    Write-Host "TAG $tag count=$($tagCounts[$tag])"
  }
}

exit 0
