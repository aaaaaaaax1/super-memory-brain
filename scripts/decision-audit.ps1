param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$Graph = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'graph.jsonl'
$Particles = Join-Path $MemoryRoot 'decision_particles.txt'
$Sandglass = Join-Path $MemoryRoot 'sandglass.txt'
$Policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$validAdrStatuses = if ($Policy.adr.statuses) { @($Policy.adr.statuses) } else { @('proposed','accepted','deprecated','superseded','rejected') }
$currentAdrStatuses = if ($Policy.adr.currentStatuses) { @($Policy.adr.currentStatuses) } else { @('proposed','accepted') }
$requiredAdrRelations = if ($Policy.adr.requiredRelations) { @($Policy.adr.requiredRelations) } else { @('decides','has_title','has_status','has_context','has_consequence') }

function Get-Meta($Map, [string]$Subject) {
  if (-not $Map.ContainsKey($Subject)) {
    $Map[$Subject] = [pscustomobject]@{
      subject = $Subject
      tags = @()
      relations = @{}
      status = ''
      supersedes = @()
      supersededBy = @()
      isAdr = $false
    }
  }
  return $Map[$Subject]
}

$graphParseErrors = 0
$decisionGraph = @()
$adrBySubject = @{}
$lineNumber = 0
if (Test-Path $Graph) {
  foreach ($line in @(Get-Content -LiteralPath $Graph -Encoding UTF8)) {
    $lineNumber += 1
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $cleanLine = $line.TrimStart([char]0xFEFF)
    try {
      $node = $cleanLine | ConvertFrom-Json
      $tags = [string]$node.tags
      $subject = [string]$node.subject
      if ($tags.Contains('[DECISION]') -or $tags.Contains('[ADR]') -or $subject.StartsWith('decision:')) {
        $entry = [pscustomobject]@{ line = $lineNumber; node = $node }
        $decisionGraph += $entry
        $meta = Get-Meta $adrBySubject $subject
        if ($tags.Contains('[ADR]')) { $meta.isAdr = $true }
        $meta.tags = @($meta.tags + $tags)
        $relation = [string]$node.relation
        if (-not $meta.relations.ContainsKey($relation)) { $meta.relations[$relation] = @() }
        $meta.relations[$relation] = @($meta.relations[$relation] + [string]$node.object)
        if ($relation -eq 'has_status') { $meta.status = [string]$node.object; $meta.isAdr = $true }
        if ($relation -in @('has_title','has_context','has_consequence','has_owner','affects','has_alternative')) { $meta.isAdr = $true }
        if ($relation -eq 'supersedes') { $meta.supersedes = @($meta.supersedes + [string]$node.object) }
        if ($relation -eq 'superseded_by') { $meta.supersededBy = @($meta.supersededBy + [string]$node.object) }
      }
    } catch {
      $graphParseErrors += 1
    }
  }
}

foreach ($entry in $decisionGraph) {
  if ([string]$entry.node.relation -eq 'supersedes') {
    $oldSubject = [string]$entry.node.object
    if ($oldSubject.StartsWith('decision:')) {
      $oldMeta = Get-Meta $adrBySubject $oldSubject
      $oldMeta.supersededBy = @($oldMeta.supersededBy + [string]$entry.node.subject)
    }
  }
}

$currentGroups = @($decisionGraph |
  Where-Object { ([string]$_.node.tags).Contains('[CURRENT]') -and ([string]$_.node.relation) -eq 'decides' } |
  Group-Object { $_.node.subject } |
  Where-Object { $_.Count -gt 1 })

$unverifiedDecisionGraphCount = @($decisionGraph | Where-Object { -not ([string]$_.node.tags).Contains('[VERIFIED]') }).Count

$particleLines = @()
if (Test-Path $Particles) {
  $particleLines = @(Get-Content -LiteralPath $Particles -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$malformedParticles = 0
foreach ($line in $particleLines) {
  $parts = $line -split ' \| '
  if ($parts.Count -lt 6) { $malformedParticles += 1 }
}

$decisionMemoryLines = @()
if (Test-Path $Sandglass) {
  $decisionMemoryLines = @(Get-Content -LiteralPath $Sandglass -Encoding UTF8 | Where-Object { $_ -like '*[DECISION]*' })
}

$graphBySubject = @{}
foreach ($entry in $decisionGraph) {
  $graphBySubject[[string]$entry.node.subject] = $true
}

$legacyDecisionMemoryCount = 0
foreach ($line in $decisionMemoryLines) {
  $match = [regex]::Match($line, 'key=([^\s]+)')
  if (-not $match.Success) {
    $legacyDecisionMemoryCount += 1
    continue
  }
  $subject = 'decision:' + $match.Groups[1].Value
  if (-not $graphBySubject.ContainsKey($subject)) { $legacyDecisionMemoryCount += 1 }
}

$adrState = Get-SuperBrainAdrState -DecisionNodes @($decisionGraph | ForEach-Object { $_.node }) -Policy $Policy
$missingAdrSchema = @($adrState.missingSchema)
$invalidAdrStatus = @($adrState.invalidStatus)
$adrSupersedesMissing = @($adrState.supersedesMissing)
$adrSchemaIssueCount = $adrState.schemaIssueCount
$ok = ($graphParseErrors -eq 0 -and $currentGroups.Count -eq 0 -and $unverifiedDecisionGraphCount -eq 0 -and $adrSchemaIssueCount -eq 0)
$result = [pscustomobject]@{
  ok = $ok
  graph = $Graph
  decisionParticlePath = $Particles
  graphParseErrorCount = $graphParseErrors
  decisionGraphCount = $decisionGraph.Count
  decisionCurrentConflictCount = $currentGroups.Count
  unverifiedDecisionGraphCount = $unverifiedDecisionGraphCount
  decisionParticleCount = $particleLines.Count
  malformedDecisionParticleCount = $malformedParticles
  decisionMemoryCount = $decisionMemoryLines.Count
  legacyDecisionMemoryCount = $legacyDecisionMemoryCount
  adrGraphCount = $adrState.subjectCount
  adrCurrentCount = $adrState.currentCount
  adrSupersededCount = $adrState.supersededCount
  adrSchemaIssueCount = $adrSchemaIssueCount
  missingAdrSchema = @($missingAdrSchema)
  invalidAdrStatus = @($invalidAdrStatus)
  adrSupersedesMissing = @($adrSupersedesMissing)
  adrCurrentConflictCount = $adrState.currentConflictCount
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "DECISION_AUDIT ok=$($result.ok) graphDecisions=$($result.decisionGraphCount) particles=$($result.decisionParticleCount) memoryDecisions=$($result.decisionMemoryCount) parseErrors=$($result.graphParseErrorCount) currentConflicts=$($result.decisionCurrentConflictCount) malformedParticles=$($result.malformedDecisionParticleCount) legacyMemory=$($result.legacyDecisionMemoryCount) adr=$($result.adrGraphCount) adrCurrent=$($result.adrCurrentCount) adrSuperseded=$($result.adrSupersededCount) adrSchemaIssues=$($result.adrSchemaIssueCount)"
}

if ($ok) { exit 0 }
exit 1
