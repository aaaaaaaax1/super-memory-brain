param(
  [string]$Summary = '',
  [string]$NextAction = '',
  [string[]]$Evidence = @(),
  [switch]$ClearCheckpoint,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
New-Item -ItemType Directory -Force -Path $workspace | Out-Null

function Invoke-JsonTool([string]$ScriptName) {
  try {
    $output = @(& (Join-Path $PSScriptRoot $ScriptName) -Json 6>$null)
    $jsonStart = -1
    for ($index = 0; $index -lt $output.Count; $index++) { if ([string]$output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break } }
    if ($jsonStart -lt 0) { throw "No JSON output from $ScriptName" }
    $jsonText = (@($output[$jsonStart..($output.Count - 1)]) -join "`n")
    return $jsonText | ConvertFrom-Json
  } catch { return [pscustomobject]@{ ok=$false; error=$_.Exception.Message } }
}
function Read-WorkspaceJson([string]$Name) { $p = Join-Path $workspace $Name; if (-not (Test-Path $p)) { return $null }; try { Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } }
function Limit-Text([string]$Text, [int]$Max = 180) { if ([string]::IsNullOrWhiteSpace($Text)) { return '' }; $value=([string]$Text).Trim(); if ($value.Length -gt $Max) { return $value.Substring(0,$Max)+'...' }; return $value }
function Limit-List([object[]]$Items, [int]$MaxItems = 8, [int]$MaxChars = 160) { @(@($Items) | Select-Object -First $MaxItems | ForEach-Object { Limit-Text ([string]$_) $MaxChars }) }

$dashboard = Invoke-JsonTool 'super-brain-dashboard.ps1'
if ($ClearCheckpoint) { try { & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Clear | Out-Null } catch {} }
if ([string]::IsNullOrWhiteSpace($Summary)) { $Summary = if ($dashboard.task -and -not [string]::IsNullOrWhiteSpace([string]$dashboard.task.summary)) { $dashboard.task.summary } else { 'Super Brain status snapshot' } }
if ([string]::IsNullOrWhiteSpace($NextAction)) { $NextAction = if ($dashboard.nextAction) { $dashboard.nextAction } else { 'Continue from dashboard state.' } }

$continuityStatus = Read-WorkspaceJson 'last-project-continuity.json'
$taskGraph = Read-WorkspaceJson 'task-graph.json'
$stepLedger = Read-WorkspaceJson 'step-ledger.json'
$impact = Read-WorkspaceJson 'last-impact-advisor.json'
$codegraph = Read-WorkspaceJson 'last-codegraph-index.json'

$continuitySummary = [pscustomobject]@{
  taskId = if ($taskGraph) { $taskGraph.taskId } else { '' }
  taskStatus = if ($taskGraph) { $taskGraph.status } else { '' }
  goal = if ($taskGraph) { Limit-Text $taskGraph.goal 220 } else { '' }
  openStepCount = if ($stepLedger) { @($stepLedger.openSteps).Count } else { 0 }
  completedCount = if ($stepLedger) { @($stepLedger.completedSteps).Count } else { 0 }
  skippedCount = if ($stepLedger) { @($stepLedger.skippedSteps).Count } else { 0 }
  candidateFindings = if ($continuityStatus -and $continuityStatus.findingCounts) { [int]$continuityStatus.findingCounts.candidate } else { 0 }
  nextAction = if ($continuityStatus) { Limit-Text $continuityStatus.nextAction 220 } else { '' }
}
$impactSummary = [pscustomobject]@{
  riskLevel = if ($impact) { [string]$impact.riskLevel } else { '' }
  affectedScripts = if ($impact) { @(Limit-List @($impact.affectedScripts) 10 120) } else { @() }
  recommendedChecks = if ($impact) { @(Limit-List @($impact.recommendedChecks) 10 160) } else { @() }
}
$codegraphSummary = [pscustomobject]@{
  schema = if ($codegraph) { [string]$codegraph.schema } else { '' }
  scriptCount = if ($codegraph -and $codegraph.summary) { [int]$codegraph.summary.scriptCount } else { 0 }
  dynamicCallUnknownCount = if ($codegraph -and $codegraph.summary) { [int]$codegraph.summary.dynamicCallUnknownCount } else { 0 }
  workspaceFileCount = if ($codegraph -and $codegraph.summary) { [int]$codegraph.summary.workspaceFileCount } else { 0 }
}

$snapshot = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $dashboard.version
  summary = Limit-Text $Summary 180
  nextAction = Limit-Text $NextAction 220
  roadmapCompletedVersions = @($dashboard.roadmap.completedVersions)
  roadmapRemainingVersions = @($dashboard.roadmap.remainingVersions)
  verifyOk = $dashboard.verify.ok
  hotRefreshOk = $dashboard.hotRefresh.ok
  memoryRegressionOk = $dashboard.memoryRegression.ok
  reviewGateOk = $dashboard.reviewGate.ok
  privacyOk = $dashboard.privacy.ok
  risks = @(Limit-List @($dashboard.risks) 8 120)
  continuity = $continuitySummary
  impact = $impactSummary
  codegraph = $codegraphSummary
  evidence = @(Limit-List @($Evidence + @('super-brain-dashboard.ps1','last-verify-package.json','last-task-verification.json','last-project-continuity.json','task-graph.json','last-impact-advisor.json','last-codegraph-index.json')) 10 160)
}

$path = Join-Path $workspace 'last-status-snapshot.json'
Write-JsonUtf8NoBom $path $snapshot 12
$statusCard = [pscustomobject]@{ ok=$snapshot.ok; updatedAt=$snapshot.checkedAt; version=$snapshot.version; packageOk=$dashboard.ok; verifyOk=$snapshot.verifyOk; hotRefreshOk=$snapshot.hotRefreshOk; memoryRegressionOk=$snapshot.memoryRegressionOk; reviewGateOk=$snapshot.reviewGateOk; privacyOk=$snapshot.privacyOk; risksCount=@($snapshot.risks).Count; nextAction=$snapshot.nextAction; continuity=$continuitySummary; impact=$impactSummary; codegraph=$codegraphSummary; source='status-snapshot-writer.ps1' }
$statusCardPath = Join-Path $workspace 'status-card.json'
Write-JsonUtf8NoBom $statusCardPath $statusCard 10
if ($Json) { $snapshot | Add-Member -NotePropertyName statusCardPath -NotePropertyValue $statusCardPath -Force; $snapshot | ConvertTo-Json -Depth 12 } else { Write-Host "STATUS_SNAPSHOT_WRITER ok=True path=$path version=$($snapshot.version) statusCard=$statusCardPath"; Write-Host "STATUS_SNAPSHOT_SUMMARY $($snapshot.summary)"; Write-Host "STATUS_SNAPSHOT_NEXT $($snapshot.nextAction)" }
exit 0
