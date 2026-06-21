param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Convert-ToolJson([object[]]$Output, [string]$ScriptName) {
  $jsonStart = -1
  for ($index = 0; $index -lt $Output.Count; $index++) {
    if ([string]$Output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
  }
  if ($jsonStart -lt 0) { return [pscustomobject]@{ ok=$false; error="No JSON from $ScriptName" } }
  return ((@($Output[$jsonStart..($Output.Count - 1)]) -join "`n") | ConvertFrom-Json)
}

$inputText = (($Text -join ' ').Trim())
$intent = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'intent-router.ps1') $inputText -Json 6>$null) 'intent-router.ps1'
$continuation = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'auto-continuation.ps1') -Json 6>$null) 'auto-continuation.ps1'
$dashboard = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'super-brain-dashboard.ps1') -Json 6>$null) 'super-brain-dashboard.ps1'
$dispatchLearning = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'dispatch-learning.ps1') -Json 6>$null) 'dispatch-learning.ps1'

$nextAction = if ($continuation.nextAction) { [string]$continuation.nextAction } else { 'Ask for the next concrete user task.' }
$confidence = 0.7
$why = @('auto-continuation')
$commands = @('scripts\super-brain-dashboard.ps1 -Json')

if ($intent.intent -eq 'release') {
  $nextAction = 'Run release-readiness, then release-share if ready.'
  $commands = @('scripts\release-readiness.ps1 -Json','scripts\release-share.ps1')
  $why += 'release_intent'
  $confidence = 0.88
} elseif ($intent.intent -eq 'status') {
  $nextAction = 'Read health-summary and dashboard before changing state.'
  $commands = @('scripts\health-summary.ps1 -Json','scripts\super-brain-dashboard.ps1 -Json')
  $why += 'status_intent'
  $confidence = 0.86
} elseif ($intent.intent -eq 'team_or_review') {
  $nextAction = 'Review dispatch learning and agent scorecard before team/review-board work.'
  $commands = @('scripts\dispatch-learning.ps1 -Json','scripts\agent-scorecard.ps1 -Json','scripts\team-task-review-gate.ps1 -Json')
  $why += 'team_intent'
  $confidence = 0.84
} elseif ($intent.intent -eq 'add_or_optimize_feature') {
  $nextAction = 'Implement the focused feature, then run verify-package and CI.'
  $commands = @('scripts\verify-package.ps1','scripts\ci.ps1')
  $why += 'feature_intent'
  $confidence = 0.8
}

$result = [pscustomobject]@{
  ok = ($dashboard.ok -eq $true -and $continuation.ok -eq $true)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $dashboard.version
  input = $inputText
  intent = $intent.intent
  confidence = $confidence
  nextAction = $nextAction
  why = @($why)
  commands = @($commands)
  blockers = @($continuation.blockers)
  dispatchRecommendations = @($dispatchLearning.recommendations | Select-Object -First 3)
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "SMART_NEXT intent=$($result.intent) action=$($result.nextAction) blockers=$(@($result.blockers).Count)" }
if (-not $result.ok) { exit 1 }
exit 0
