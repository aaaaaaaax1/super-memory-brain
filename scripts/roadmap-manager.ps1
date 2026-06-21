param(
  [string]$Query = 'agent subagent roadmap',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

$manifest = Get-SuperBrainManifest $Root
$baseline = Get-Content -LiteralPath (Join-Path $Root 'CURRENT_BASELINE.md') -Raw -Encoding UTF8
$roadmapJson = & (Join-Path $PSScriptRoot 'decision-search.ps1') -Query $Query -AdrOnly -TopK 5 -MaxTokens 800 -Json
$roadmap = @()
try { $roadmap = @($roadmapJson | ConvertFrom-Json) } catch { $roadmap = @() }
$teamStatusJson = & (Join-Path $PSScriptRoot 'team-task-status.ps1') -Json
$teamStatus = $null
try { $teamStatus = $teamStatusJson | ConvertFrom-Json } catch {}
$lastTaskVerification = Read-WorkspaceJson 'last-task-verification.json'

$completed = @()
foreach ($version in @('0.5.20','0.5.21','0.5.22','0.5.23')) {
  if ($baseline.Contains($version) -or ($roadmapJson -like "*$version*")) { $completed += $version }
}
$remaining = @()
foreach ($version in @('0.5.20','0.5.21','0.5.22','0.5.23')) {
  if ($completed -notcontains $version) { $remaining += $version }
}

$result = [pscustomobject]@{
  ok = (@($roadmap).Count -gt 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $manifest.version
  query = $Query
  roadmapFound = (@($roadmap).Count -gt 0)
  currentRoadmap = if (@($roadmap).Count -gt 0) { $roadmap[0] } else { $null }
  completedVersions = @($completed)
  remainingVersions = @($remaining)
  teamTaskCount = if ($teamStatus) { $teamStatus.count } else { $null }
  lastTaskSummary = if ($lastTaskVerification) { $lastTaskVerification.summary } else { '' }
  evidence = @('decision-search.ps1', 'CURRENT_BASELINE.md', 'team-task-status.ps1', 'last-task-verification.json')
}

if ($Json) {
  $result | ConvertTo-Json -Depth 12
} else {
  Write-Host "ROADMAP_MANAGER ok=$($result.ok) version=$($result.version) completed=$(@($completed) -join ',') remaining=$(@($remaining) -join ',') found=$($result.roadmapFound)"
  if (@($roadmap).Count -gt 0) { Write-Host "ROADMAP_CURRENT $($roadmap[0].adr.title)" }
}
if (-not $result.ok) { exit 1 }
exit 0
