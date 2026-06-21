param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$baseMemoryRoot = Get-SuperBrainMemoryBaseRoot $Root
$policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$files = @(
  (Join-Path $memoryRoot 'sandglass.txt'),
  (Join-Path $memoryRoot 'decision_particles.txt'),
  (Join-Path $baseMemoryRoot 'graph.jsonl')
)
$hits = @()
foreach ($file in $files) {
  if (-not (Test-Path $file)) { continue }
  $lineNumber = 0
  foreach ($line in Get-Content -LiteralPath $file -Encoding UTF8) {
    $lineNumber += 1
    $lower = $line.ToLowerInvariant()
    foreach ($pattern in @($policy.privatePatterns)) {
      if ($lower.Contains($pattern.ToLowerInvariant())) {
        $preview = $line
        if ($preview.Length -gt 160) { $preview = $preview.Substring(0, 160) + '...' }
        $likelyFalsePositive = ($pattern -in @('private','secret','token') -and $line -match '\[PRIVACY\]|privacy|private-pattern|privatePattern')
        if ($pattern -eq 'token' -and $line -match 'token cache buckets|token bucket|cache bucket|usage reports|cache token|token cost|token usage|context tokens|fragmentation|responses route|cache metric|cache work|warm.*gap|baseline.*cache') { $likelyFalsePositive = $true }
        $hits += [pscustomobject]@{
          file = $file
          line = $lineNumber
          pattern = $pattern
          preview = $preview
          likelyFalsePositive = $likelyFalsePositive
        }
        break
      }
    }
  }
}
$result = [pscustomobject]@{
  ok = ($hits.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  memoryRoot = $memoryRoot
  hitCount = $hits.Count
  hits = @($hits)
  recommendation = if ($hits.Count -eq 0) { 'No private-pattern hits found.' } else { 'Review hits before sharing; do not auto-delete without confirmation.' }
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else {
  Write-Host "PRIVACY_HIT_LOCATOR ok=$($result.ok) hits=$($result.hitCount)"
  foreach ($hit in @($hits)) { Write-Host "PRIVACY_HIT file=$($hit.file) line=$($hit.line) pattern=$($hit.pattern) falsePositive=$($hit.likelyFalsePositive)" }
}
if (-not $result.ok) { exit 1 }
exit 0
