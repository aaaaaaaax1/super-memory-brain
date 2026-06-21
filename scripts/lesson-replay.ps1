param(
  [string]$Query = '',
  [int]$TopK = 5,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$indexPath = Join-Path $workspace 'experience-index.md'
$entries = @()
$current = $null

if (Test-Path $indexPath) {
  foreach ($line in Get-Content -LiteralPath $indexPath -Encoding UTF8) {
    if ($line -match '^###\s+(.+)$') {
      if ($current) { $entries += [pscustomobject]$current }
      $current = [ordered]@{ id=$Matches[1]; title=''; status=''; confidence=''; triggers=''; scope=''; recallQuery=''; evidencePaths=''; score=0 }
      continue
    }
    if (-not $current) { continue }
    if ($line -match '^- Title:\s*(.+)$') { $current.title = $Matches[1] }
    elseif ($line -match '^- Status:\s*(.+)$') { $current.status = $Matches[1] }
    elseif ($line -match '^- Confidence:\s*(.+)$') { $current.confidence = $Matches[1] }
    elseif ($line -match '^- Triggers:\s*(.+)$') { $current.triggers = $Matches[1] }
    elseif ($line -match '^- Scope:\s*(.+)$') { $current.scope = $Matches[1] }
    elseif ($line -match '^- Recall Query:\s*(.+)$') { $current.recallQuery = $Matches[1] }
    elseif ($line -match '^- Evidence Paths:\s*(.+)$') { $current.evidencePaths = $Matches[1] }
  }
  if ($current) { $entries += [pscustomobject]$current }
}

$terms = @()
if (-not [string]::IsNullOrWhiteSpace($Query)) {
  $terms = @($Query.ToLowerInvariant() -split '[^\p{L}\p{Nd}\.]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
foreach ($entry in $entries) {
  $score = 0
  $fields = @(
    @{ value = $entry.title; weight = 5 },
    @{ value = $entry.triggers; weight = 4 },
    @{ value = $entry.recallQuery; weight = 3 },
    @{ value = $entry.scope; weight = 2 },
    @{ value = $entry.evidencePaths; weight = 1 },
    @{ value = $entry.id; weight = 1 }
  )
  foreach ($term in $terms) {
    foreach ($field in $fields) {
      $value = ([string]$field.value).ToLowerInvariant()
      if ($value.Contains($term)) { $score += [int]$field.weight }
    }
  }
  if ($terms.Count -eq 0) { $score = 1 }
  $entry.score = $score
}
$matches = @($entries | Where-Object { $_.score -gt 0 } | Sort-Object @{ Expression='score'; Descending=$true }, @{ Expression='id'; Descending=$false } | Select-Object -First $TopK)
$result = [pscustomObject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  query = $Query
  indexPath = $indexPath
  total = $entries.Count
  count = $matches.Count
  matches = @($matches)
  recommendation = if ($matches.Count -gt 0) { 'Review matching lessons before changing direction.' } else { 'No matching lessons found.' }
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else {
  Write-Host "LESSON_REPLAY ok=True query=$Query count=$($matches.Count) total=$($entries.Count)"
  foreach ($match in @($matches)) { Write-Host "LESSON_REPLAY_MATCH id=$($match.id) score=$($match.score) title=$($match.title)" }
}
exit 0
