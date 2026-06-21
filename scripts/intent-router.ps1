param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$inputText = (($Text -join ' ').Trim())
$normalized = $inputText.ToLowerInvariant()
$intent = 'general_task'
$confidence = 0.55
$recommendedAction = 'Use smart-next.ps1 or ask for the next concrete task.'
$dispatchHints = @()
$commands = @('scripts\smart-next.ps1 -Json')

function U([int[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]$_ })
}

$zhContinue = U @(32487,32493)
$zhStatus = U @(29366,24577)
$zhNormal = U @(27491,24120)
$zhFix = U @(20462)
$zhFail = U @(22833,36133)
$zhFeature = U @(21151,33021)
$zhOptimize = U @(20248,21270)
$zhRelease = U @(21457,21253)
$zhShare = U @(20998,20139)
$zhMemory = U @(35760,24518)
$zhSearch = U @(25628,32034)
$zhTeam = U @(22242,38431)
$zhReview = U @(23457,26597)

function Test-Any([string[]]$Needles) {
  foreach ($needle in $Needles) {
    if ($normalized.Contains($needle.ToLowerInvariant())) { return $true }
  }
  return $false
}

if ([string]::IsNullOrWhiteSpace($normalized) -or (Test-Any @($zhContinue,'continue','resume'))) {
  $intent = 'continue'
  $confidence = 0.9
  $recommendedAction = 'Resume from auto-continuation and dashboard state.'
  $commands = @('scripts\auto-continuation.ps1 -Json','scripts\super-brain-dashboard.ps1 -Json')
  $dispatchHints = @('simple_direct')
} elseif (Test-Any @($zhStatus,$zhNormal,'status','dashboard','overall','ready')) {
  $intent = 'status'
  $confidence = 0.88
  $recommendedAction = 'Read health-summary for human status, then dashboard for full machine state.'
  $commands = @('scripts\health-summary.ps1 -Json','scripts\super-brain-dashboard.ps1 -Json')
} elseif (Test-Any @($zhFix,$zhFail,'bug','fix','failed','error')) {
  $intent = 'fix_bug'
  $confidence = 0.78
  $recommendedAction = 'Diagnose, patch root cause, then run targeted verification.'
  $dispatchHints = @('verification_required','logic_safety_required')
} elseif (Test-Any @($zhFeature,$zhOptimize,'feature','implement','add','optimize')) {
  $intent = 'add_or_optimize_feature'
  $confidence = 0.76
  $recommendedAction = 'Plan scope, implement focused changes, then verify through package checks.'
  $dispatchHints = @('verification_required')
} elseif (Test-Any @($zhRelease,$zhShare,'release','share','package')) {
  $intent = 'release'
  $confidence = 0.9
  $recommendedAction = 'Run release readiness, then release-share if safe.'
  $commands = @('scripts\release-readiness.ps1 -Json','scripts\release-share.ps1')
  $dispatchHints = @('release','share','verification_required')
} elseif (Test-Any @($zhMemory,$zhSearch,'memory','recall','search')) {
  $intent = 'memory_recall'
  $confidence = 0.82
  $recommendedAction = 'Use recall-search and relevant memory quality checks before changing state.'
  $commands = @('scripts\recall-search.ps1 -Query "..." -Json','scripts\memory-health.ps1 -Json')
} elseif (Test-Any @($zhTeam,$zhReview,'subagent','agent','team','cluster','review')) {
  $intent = 'team_or_review'
  $confidence = 0.86
  $recommendedAction = 'Use dispatch learning, trigger simulation, and review gate before accepting team findings.'
  $commands = @('scripts\dispatch-learning.ps1 -Json','scripts\agent-scorecard.ps1 -Json','scripts\team-task-review-gate.ps1 -Json')
  $dispatchHints = @('logic_safety_required','verification_required')
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  input = $inputText
  intent = $intent
  confidence = $confidence
  recommendedAction = $recommendedAction
  dispatchHints = @($dispatchHints)
  commands = @($commands)
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "INTENT_ROUTER intent=$intent confidence=$confidence action=$recommendedAction" }
exit 0
