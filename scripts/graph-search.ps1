param(
  [Parameter(Mandatory=$true)][string]$Query,
  [string]$Relation = '',
  [switch]$CurrentOnly,
  [switch]$IncludeStale,
  [switch]$Json
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$Graph = Join-Path $Root 'memory\graph.jsonl'

function Get-Rank($Item) {
  $tags = [string]$Item.tags
  if ($tags.Contains('[CURRENT]') -and $tags.Contains('[VERIFIED]')) { return 0 }
  if ($tags.Contains('[VERIFIED]')) { return 1 }
  if ($tags.Contains('[HISTORY]')) { return 2 }
  if ($tags.Contains('[STALE]')) { return 3 }
  return 4
}

if (-not (Test-Path $Graph)) {
  if ($Json) { @() | ConvertTo-Json -Depth 6 } else { Write-Host "MISSING graph: $Graph" }
  exit 1
}

$items = @()
$rawMatches = @()
$lineNumber = 0
foreach ($line in @(Get-Content -LiteralPath $Graph -Encoding UTF8)) {
  $lineNumber += 1
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $lineMatch = $line.ToLowerInvariant().Contains($Query.ToLowerInvariant())
  $cleanLine = $line.TrimStart([char]0xFEFF)
  try {
    $node = $cleanLine | ConvertFrom-Json
    $tags = [string]$node.tags
    if ($CurrentOnly -and -not $tags.Contains('[CURRENT]')) { continue }
    if (-not $IncludeStale -and $tags.Contains('[STALE]')) { continue }
    if (-not [string]::IsNullOrWhiteSpace($Relation) -and $node.relation -ne $Relation) { continue }

    $haystack = ($line + ' ' + $node.subject + ' ' + $node.relation + ' ' + $node.object + ' ' + $node.evidence + ' ' + $node.tags).ToLowerInvariant()
    if (-not $haystack.Contains($Query.ToLowerInvariant())) { continue }

    $items += [pscustomobject]@{
      line = $lineNumber
      time = $node.time
      subject = $node.subject
      relation = $node.relation
      object = $node.object
      evidence = $node.evidence
      tags = $node.tags
      rank = Get-Rank $node
      raw = $line
    }
  } catch {
    if ($lineMatch -and [string]::IsNullOrWhiteSpace($Relation) -and -not $CurrentOnly) {
      $rawMatches += [pscustomobject]@{ line = $lineNumber; raw = $line; parseError = $true }
    }
  }
}

$items = @($items | Sort-Object rank, @{ Expression = 'time'; Descending = $true })

if ($Json) {
  $combined = @($items + $rawMatches)
  if ($combined.Count -eq 0) { '[]' } else { $combined | ConvertTo-Json -Depth 6 }
} else {
  foreach ($item in $items) { $item | ConvertTo-Json -Compress -Depth 6 }
  foreach ($item in $rawMatches) { $item.raw }
}
