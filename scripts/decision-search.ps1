param(
  [string]$Query = '',
  [string]$Key = '',
  [switch]$CurrentOnly,
  [switch]$IncludeStale,
  [string]$Relation = '',
  [switch]$AdrOnly,
  [ValidateSet('','proposed','accepted','deprecated','superseded','rejected')]
  [string]$Status = '',
  [string]$Owner = '',
  [string]$Scope = '',
  [int]$TopK = 0,
  [int]$MaxTokens = 0,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Graph = Join-Path $Root 'memory\graph.jsonl'
$PolicyPath = Join-Path $Root 'memory-policy.json'
$Policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($TopK -le 0) { $TopK = [int]$Policy.retrieval.top_k }
if ($MaxTokens -le 0) { $MaxTokens = [int]$Policy.retrieval.max_tokens }
$maxChars = [Math]::Max($MaxTokens * 4, 1)
$currentStatuses = if ($Policy.adr.currentStatuses) { @($Policy.adr.currentStatuses) } else { @('proposed','accepted') }

function Get-DecisionKey([string]$Text) {
  $normalized = $Text.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+', '-'
  $normalized = $normalized.Trim('-')
  if ($normalized.Length -gt 48) { $normalized = $normalized.Substring(0, 48).Trim('-') }
  return $normalized
}

function Get-Rank($Item) {
  $tags = [string]$Item.tags
  $rank = 5
  if ($tags.Contains('[CURRENT]') -and $tags.Contains('[VERIFIED]')) { $rank = 0 }
  elseif ($tags.Contains('[VERIFIED]')) { $rank = 1 }
  elseif ($tags.Contains('[HISTORY]')) { $rank = 2 }
  elseif ($tags.Contains('[STALE]')) { $rank = 4 }
  if ($tags.Contains('[ADR]')) { $rank -= 1 }
  if ($Item.superseded -eq $true) { $rank += 5 }
  return $rank
}

function Get-Meta($Map, [string]$Subject) {
  if (-not $Map.ContainsKey($Subject)) {
    $Map[$Subject] = [pscustomobject]@{
      subject = $Subject
      title = ''
      status = ''
      context = ''
      consequence = ''
      owner = ''
      scope = ''
      alternatives = @()
      supersedes = @()
      supersededBy = @()
      isAdr = $false
    }
  }
  return $Map[$Subject]
}

function Test-QueryMatch([string]$Haystack, [string]$Needle) {
  if ([string]::IsNullOrWhiteSpace($Needle)) { return $true }
  $lowerHaystack = $Haystack.ToLowerInvariant()
  $terms = @($Needle.ToLowerInvariant() -split '[^\p{L}\p{Nd}\.]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($terms.Count -eq 0) { return $true }
  foreach ($term in $terms) {
    if (-not $lowerHaystack.Contains($term)) { return $false }
  }
  return $true
}

if (-not (Test-Path $Graph)) {
  if ($Json) { @() | ConvertTo-Json -Depth 6 } else { Write-Host "MISSING graph: $Graph" }
  exit 1
}

$keySubject = ''
if (-not [string]::IsNullOrWhiteSpace($Key)) {
  $keySubject = $Key
  if (-not $keySubject.StartsWith('decision:')) { $keySubject = 'decision:' + (Get-DecisionKey $keySubject) }
}

$rawItems = @()
$metaBySubject = @{}
$lineNumber = 0
foreach ($line in @(Get-Content -LiteralPath $Graph -Encoding UTF8)) {
  $lineNumber += 1
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  try {
    $node = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json
  } catch {
    continue
  }

  $subject = [string]$node.subject
  $tags = [string]$node.tags
  if (-not $tags.Contains('[DECISION]') -and -not $tags.Contains('[ADR]') -and -not $subject.StartsWith('decision:')) { continue }

  $meta = Get-Meta $metaBySubject $subject
  if ($tags.Contains('[ADR]')) { $meta.isAdr = $true }
  switch ([string]$node.relation) {
    'has_title' { $meta.title = [string]$node.object; $meta.isAdr = $true }
    'has_status' { $meta.status = [string]$node.object; $meta.isAdr = $true }
    'has_context' { $meta.context = [string]$node.object; $meta.isAdr = $true }
    'has_consequence' { $meta.consequence = [string]$node.object; $meta.isAdr = $true }
    'has_owner' { $meta.owner = [string]$node.object; $meta.isAdr = $true }
    'affects' { $meta.scope = [string]$node.object; $meta.isAdr = $true }
    'has_alternative' { $meta.alternatives = @($meta.alternatives + [string]$node.object); $meta.isAdr = $true }
    'supersedes' { $meta.supersedes = @($meta.supersedes + [string]$node.object) }
    'superseded_by' { $meta.supersededBy = @($meta.supersededBy + [string]$node.object) }
  }

  $rawItems += [pscustomobject]@{
    line = $lineNumber
    time = $node.time
    subject = $subject
    relation = $node.relation
    object = $node.object
    evidence = $node.evidence
    tags = $node.tags
    raw = $line
  }
}

foreach ($item in $rawItems) {
  if ($item.relation -eq 'supersedes') {
    $oldSubject = [string]$item.object
    if ($oldSubject.StartsWith('decision:')) {
      $oldMeta = Get-Meta $metaBySubject $oldSubject
      $oldMeta.supersededBy = @($oldMeta.supersededBy + [string]$item.subject)
    }
  }
}

$items = @()
foreach ($item in $rawItems) {
  $meta = Get-Meta $metaBySubject ([string]$item.subject)
  $superseded = @($meta.supersededBy).Count -gt 0
  $isAdr = ($meta.isAdr -or ([string]$item.tags).Contains('[ADR]'))
  $statusValue = if (-not [string]::IsNullOrWhiteSpace($meta.status)) { $meta.status } else { '' }

  if ($AdrOnly -and -not $isAdr) { continue }
  if ($CurrentOnly -and -not (([string]$item.tags).Contains('[CURRENT]') -or ($currentStatuses -contains $statusValue))) { continue }
  if (-not $IncludeStale -and (([string]$item.tags).Contains('[STALE]') -or $superseded)) { continue }
  if (-not [string]::IsNullOrWhiteSpace($Relation) -and $item.relation -ne $Relation) { continue }
  if (-not [string]::IsNullOrWhiteSpace($keySubject) -and $item.subject -ne $keySubject) { continue }
  if (-not [string]::IsNullOrWhiteSpace($Status) -and $statusValue -ne $Status) { continue }
  if (-not [string]::IsNullOrWhiteSpace($Owner) -and -not ([string]$meta.owner).ToLowerInvariant().Contains($Owner.ToLowerInvariant())) { continue }
  if (-not [string]::IsNullOrWhiteSpace($Scope) -and -not ([string]$meta.scope).ToLowerInvariant().Contains($Scope.ToLowerInvariant())) { continue }
  if (-not [string]::IsNullOrWhiteSpace($Query)) {
    $haystack = ($item.raw + ' ' + $meta.title + ' ' + $meta.status + ' ' + $meta.context + ' ' + $meta.consequence + ' ' + $meta.owner + ' ' + $meta.scope + ' ' + (@($meta.alternatives) -join ' ')).ToLowerInvariant()
    if (-not (Test-QueryMatch $haystack $Query)) { continue }
  }

  $out = [pscustomobject]@{
    line = $item.line
    time = $item.time
    subject = $item.subject
    relation = $item.relation
    object = $item.object
    evidence = $item.evidence
    tags = $item.tags
    rank = 0
    adr = [pscustomobject]@{
      isAdr = $isAdr
      title = $meta.title
      status = $statusValue
      context = $meta.context
      consequence = $meta.consequence
      owner = $meta.owner
      scope = $meta.scope
      alternatives = @($meta.alternatives)
      supersedes = @($meta.supersedes)
      supersededBy = @($meta.supersededBy)
      superseded = $superseded
    }
  }
  $out.rank = Get-Rank $out
  $items += $out
}

$items = @($items | Sort-Object rank, @{ Expression = 'time'; Descending = $true })
$selected = @()
$usedChars = 0
foreach ($item in $items) {
  if ($selected.Count -ge $TopK) { break }
  $text = [string]$item.object
  $nextChars = $usedChars + $text.Length
  if ($nextChars -gt $maxChars -and $selected.Count -gt 0) { break }
  $selected += $item
  $usedChars = $nextChars
}

if ($Json) {
  if ($selected.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject @($selected) -Depth 8 }
} else {
  foreach ($item in $selected) {
    $item | ConvertTo-Json -Compress -Depth 8
  }
}
