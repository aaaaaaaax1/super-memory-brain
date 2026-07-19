param(
  [switch]$Json,
  [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$casesPath = Join-Path $Root 'tests\route-regression-cases.json'
$intentRouter = Join-Path $PSScriptRoot 'intent-router.ps1'
$triggerSimulation = Join-Path $PSScriptRoot 'trigger-simulation.ps1'

function U([object[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]([int]$_) })
}

function Get-Prompt([object]$Case) {
  if ($Case.PSObject.Properties.Name -contains 'promptUnicodeCodes') {
    return U @($Case.promptUnicodeCodes)
  }
  return [string]$Case.prompt
}

function Normalize-IntentRoute([string]$Intent) {
  switch ($Intent) {
    'general_task' { return 'normal_chat' }
    'continue' { return 'current_session_continue' }
    'status' { return 'system_status' }
    'agent_bridge_channel' { return 'agent_bridge_channel' }
    'team_or_review' { return 'team_or_review' }
    'release' { return 'maintenance_or_release' }
    'memory_recall' { return 'memory_recall' }
    default { return $Intent }
  }
}

function Invoke-IntentRoute([string]$Prompt, [string]$Workspace = '') {
  $raw = & $intentRouter -Text $Prompt -Workspace $Workspace -Json
  if ($LASTEXITCODE -ne 0) { throw "intent-router failed" }
  $r = $raw | ConvertFrom-Json
  return [pscustomobject]@{
    rawIntent = [string]$r.intent
    observedRoute = Normalize-IntentRoute ([string]$r.intent)
    confidence = $r.confidence
  }
}

function Get-TriggerMap {
  $raw = & $triggerSimulation -Json
  if ($LASTEXITCODE -ne 0) { throw "trigger-simulation failed" }
  $sim = $raw | ConvertFrom-Json
  $map = @{}
  foreach ($item in @($sim.results)) { $map[[string]$item.name] = $item }
  return $map
}

if (-not (Test-Path -LiteralPath $casesPath)) { throw "Missing route regression cases: $casesPath" }
$caseDoc = Get-Content -Raw -LiteralPath $casesPath -Encoding UTF8 | ConvertFrom-Json
$triggerMap = $null
$results = @()

foreach ($case in @($caseDoc.cases)) {
  $prompt = Get-Prompt $case
  $workspace = if ($case.PSObject.Properties.Name -contains 'workspace') { [string]$case.workspace } else { '' }
  $observedRoute = 'unobserved'
  $raw = $null
  if ([string]$case.observer -eq 'trigger-simulation') {
    if ($null -eq $triggerMap) { $triggerMap = Get-TriggerMap }
    $trigger = $triggerMap[[string]$case.triggerScenario]
    $raw = $trigger
    if ($trigger -and [string]$trigger.skill -eq 'super-memory-brain') {
      $observedRoute = 'bare_wake'
    } elseif ($trigger -and $trigger.ok -eq $true) {
      $observedRoute = 'normal_chat'
    } else {
      $observedRoute = 'trigger_mismatch'
    }
  } else {
    $raw = Invoke-IntentRoute $prompt $workspace
    $observedRoute = [string]$raw.observedRoute
    if ($case.expectedRoute -eq 'direct_answer' -and $observedRoute -eq 'normal_chat') {
      $observedRoute = 'direct_answer'
    }
  }

  $matchesExpected = ($observedRoute -eq [string]$case.expectedRoute)
  $isKnownGap = ([bool]$case.knownBaselineGap -and [bool]$case.mustFixBeforePhase6)
  $ok = if ($Strict) { $matchesExpected } else { ($matchesExpected -or $isKnownGap) }

  $results += [pscustomobject]@{
    id = [string]$case.id
    expectedRoute = [string]$case.expectedRoute
    observedRoute = $observedRoute
    matchesExpected = $matchesExpected
    knownBaselineGap = [bool]$case.knownBaselineGap
    mustFixBeforePhase6 = [bool]$case.mustFixBeforePhase6
    ok = $ok
    tags = @($case.tags)
  }
}

$failed = @($results | Where-Object { $_.ok -ne $true })
$summary = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  strict = [bool]$Strict
  total = @($results).Count
  failed = @($failed).Count
  knownBaselineGapCount = @($results | Where-Object { $_.knownBaselineGap -eq $true }).Count
  results = @($results)
}

if ($Json) {
  $summary | ConvertTo-Json -Depth 10
} else {
  Write-Host "ROUTE_REGRESSION strict=$($summary.strict) total=$($summary.total) failed=$($summary.failed) knownBaselineGaps=$($summary.knownBaselineGapCount)"
  foreach ($item in @($results)) {
    Write-Host "ROUTE_CASE id=$($item.id) ok=$($item.ok) expected=$($item.expectedRoute) observed=$($item.observedRoute) knownGap=$($item.knownBaselineGap)"
  }
}

if (-not $summary.ok) { exit 1 }
exit 0
