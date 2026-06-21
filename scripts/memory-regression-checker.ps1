param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

$cases = @(
  @{ name='agent-subagent-roadmap'; command='decision-search'; query='agent subagent roadmap'; min=1 },
  @{ name='subagent-team-memory'; command='team-memory-retrieval'; query='subagent'; min=1 },
  @{ name='version-0523-team-memory'; command='team-memory-retrieval'; query='0.5.23'; min=1 },
  @{ name='roadmap-manager'; command='roadmap-manager'; query='agent subagent roadmap'; min=1 },
  @{ name='g1-display-rule'; command='decision-search'; query='G1 display rule'; min=1 }
)

$results = @()
foreach ($case in $cases) {
  $count = 0
  $ok = $false
  $errorMessage = ''
  try {
    if ($case.command -eq 'decision-search') {
      $jsonText = & (Join-Path $PSScriptRoot 'decision-search.ps1') -Query $case.query -TopK 5 -MaxTokens 800 -Json
      $items = @($jsonText | ConvertFrom-Json)
      $count = @($items).Count
    } elseif ($case.command -eq 'team-memory-retrieval') {
      $jsonText = & (Join-Path $PSScriptRoot 'team-memory-retrieval.ps1') -Query $case.query -TopK 5 -Json
      $obj = $jsonText | ConvertFrom-Json
      $count = [int]$obj.count
    } elseif ($case.command -eq 'roadmap-manager') {
      $jsonText = & (Join-Path $PSScriptRoot 'roadmap-manager.ps1') -Query $case.query -Json
      $obj = $jsonText | ConvertFrom-Json
      $count = if ($obj.roadmapFound -eq $true) { 1 } else { 0 }
    }
    $ok = ($count -ge [int]$case.min)
  } catch {
    $errorMessage = $_.Exception.Message
  }
  $results += [pscustomobject]@{
    name = $case.name
    command = $case.command
    query = $case.query
    expectedMin = [int]$case.min
    count = $count
    ok = $ok
    error = $errorMessage
  }
}

$failed = @($results | Where-Object { $_.ok -ne $true })
$result = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  total = @($results).Count
  failed = $failed.Count
  results = @($results)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "MEMORY_REGRESSION ok=$($result.ok) total=$($result.total) failed=$($result.failed)"
  foreach ($item in @($results)) { Write-Host "MEMORY_REGRESSION_CASE name=$($item.name) ok=$($item.ok) count=$($item.count) query=$($item.query)" }
}
if (-not $result.ok) { exit 1 }
exit 0
