param(
  [string]$PlanPath = '',
  [string]$TaskId = '',
  [string]$ActualResult = '',
  [string[]]$Evidence = @(),
  [ValidateSet('keep','revise','rollback','unknown')]
  [string]$Decision = 'unknown',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$planRoot = Join-Path $workspace 'change-causality'
$reviewRoot = Join-Path $workspace 'change-causality-reviews'
$scopeRoot = Join-Path $workspace 'guard-state'
$taskPlanRoot = Join-Path $scopeRoot 'change-causality'
$taskReviewRoot = Join-Path $scopeRoot 'change-causality-reviews'
$currentVersion = [string](Get-SuperBrainManifest $Root).version
$taskIdProvided = -not [string]::IsNullOrWhiteSpace($TaskId)
foreach ($dir in @($workspace,$reviewRoot,$taskPlanRoot,$taskReviewRoot)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
$outPath = Join-Path $workspace 'last-causal-change-review.json'

function Limit-Text([string]$Value, [int]$Max = 600) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '\s+', ' '
  if ($v.Length -gt $Max) { return $v.Substring(0, $Max) + '...' }
  return $v
}
function Get-Hash([string]$Raw) { $sha=[Security.Cryptography.SHA256]::Create(); -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Raw))[0..7] | ForEach-Object { $_.ToString('x2') }) }
function Add-Gap($List,[string]$Code,[string]$EvidenceText,[string]$Severity='medium'){ [void]$List.Add([pscustomobject]@{ code=$Code; severity=$Severity; evidence=Limit-Text $EvidenceText 420 }) }
function Read-JsonFile([string]$Path){ if(Test-Path -LiteralPath $Path){ try{ return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }catch{} }; return $null }
function Safe-TaskId([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; if ($safe.Length -gt 120) { return $safe.Substring(0,120) }; return $safe }
function Get-TaskDir([string]$Base,[string]$Value) { $safe=Safe-TaskId $Value; if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; $dir=Join-Path $Base $safe; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }; return $dir }
function Get-PlanSearchRoots {
  if ($taskIdProvided) {
    $safe = Safe-TaskId $TaskId
    if ([string]::IsNullOrWhiteSpace($safe)) { return @() }
    return @(Join-Path $taskPlanRoot $safe)
  }
  return @($planRoot)
}
function Find-PlanCandidate([string]$SearchRoot,[string]$RequiredTaskId='') {
  if (-not (Test-Path -LiteralPath $SearchRoot)) { return $null }
  foreach ($file in @(Get-ChildItem -LiteralPath $SearchRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object @{Expression='LastWriteTime';Descending=$true}, @{Expression='Name';Descending=$false})) {
    $obj = Read-JsonFile $file.FullName
    if (-not $obj) { continue }
    if ([string]::IsNullOrWhiteSpace($RequiredTaskId) -or [string]$obj.taskId -eq $RequiredTaskId) {
      return [pscustomobject]@{ path=$file.FullName; value=$obj }
    }
  }
  return $null
}

$plan = $null
$planSelection = 'none'
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
  $plan = Read-JsonFile $PlanPath
  $planSelection = 'explicit_path'
} else {
  foreach ($searchRoot in Get-PlanSearchRoots) {
    $candidate = Find-PlanCandidate $searchRoot $(if ($taskIdProvided) { $TaskId } else { '' })
    if ($candidate) {
      $plan = $candidate.value
      $PlanPath = $candidate.path
      $planSelection = if ($taskIdProvided) { 'task_scoped' } else { 'global_latest' }
      break
    }
  }
}

$gaps = New-Object System.Collections.ArrayList
if (-not $plan) { Add-Gap $gaps 'missing_causal_change_plan' 'No causal change plan found to review.' 'high' }
if ([string]::IsNullOrWhiteSpace($ActualResult)) { Add-Gap $gaps 'missing_actual_result' 'ActualResult is required for expected-vs-actual review.' 'high' }
if (@($Evidence).Count -eq 0) { Add-Gap $gaps 'missing_review_evidence' 'Evidence is required before keeping/revising a causal hypothesis.' 'medium' }
if ($Decision -eq 'unknown') { Add-Gap $gaps 'missing_keep_revise_rollback_decision' 'Decision should state keep, revise, or rollback after checking evidence.' 'medium' }

$planTaskId = if ($plan) { [string]$plan.taskId } else { '' }
$planVersion = if ($plan) { [string]$plan.version } else { '' }
$planTaskMatch = if ($plan) {
  if ($taskIdProvided) { $planTaskId -eq $TaskId }
  else { [string]::IsNullOrWhiteSpace($planTaskId) }
} else { $false }
if ($plan -and -not $planTaskMatch) {
  $required = if ($taskIdProvided) { $TaskId } else { '<unscoped plan>' }
  Add-Gap $gaps 'causal_plan_task_mismatch' "Causal plan taskId '$planTaskId' does not match required taskId '$required'." 'high'
}
if ($plan -and $planVersion -ne $currentVersion) {
  Add-Gap $gaps 'causal_plan_version_mismatch' "Causal plan version '$planVersion' does not match current package version '$currentVersion'." 'high'
}
if ($plan -and $plan.ok -ne $true) { Add-Gap $gaps 'causal_plan_not_valid' 'Causal plan must have ok=true before it can support a review.' 'high' }
$expected = if ($plan) { [string]$plan.expectedOptimization } else { '' }
$verification = if ($plan) { [string]$plan.verificationMethod } else { '' }
if ($plan -and [string]::IsNullOrWhiteSpace($expected)) { Add-Gap $gaps 'missing_expected_optimization' 'Causal plan must define expectedOptimization before expected-vs-actual review.' 'high' }
if ($plan -and [string]::IsNullOrWhiteSpace($verification)) { Add-Gap $gaps 'missing_verification_method' 'Causal plan must define verificationMethod before expected-vs-actual review.' 'high' }
$actualLower = $ActualResult.ToLowerInvariant()
$expectedLower = $expected.ToLowerInvariant()
$matched = $false
if (-not [string]::IsNullOrWhiteSpace($expectedLower) -and -not [string]::IsNullOrWhiteSpace($actualLower)) {
  foreach ($term in @($expectedLower -split '[^a-z0-9\p{L}]+' | Where-Object { $_.Length -ge 4 } | Select-Object -First 8)) {
    if ($actualLower.Contains($term)) { $matched = $true; break }
  }
}
if ($plan -and -not $matched -and $Decision -eq 'keep') { Add-Gap $gaps 'expected_actual_not_linked' 'Decision=keep but ActualResult does not mention terms from ExpectedOptimization; add stronger evidence or revise.' 'medium' }

$id = Get-Hash (($PlanPath,$ActualResult,($Evidence -join '|'),$Decision) -join '||')
$reviewDir = Get-TaskDir $taskReviewRoot $TaskId
if ([string]::IsNullOrWhiteSpace($reviewDir)) { $reviewDir = $reviewRoot }
$reviewPath = Join-Path $reviewDir ($id + '.json')
$result = [pscustomobject]@{
  ok = ($gaps.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.causal-change-review.v1'
  version = $currentVersion
  reviewId = $id
  taskId = Limit-Text $TaskId 120
  planPath = $PlanPath
  planSelection = $planSelection
  planId = if($plan){$plan.planId}else{''}
  planTaskId = Limit-Text $planTaskId 120
  planTaskMatch = $planTaskMatch
  planVersion = $planVersion
  observedProblem = if($plan){$plan.observedProblem}else{''}
  expectedOptimization = Limit-Text $expected 700
  verificationMethod = Limit-Text $verification 700
  actualResult = Limit-Text $ActualResult 900
  evidence = @($Evidence | ForEach-Object { Limit-Text $_ 360 })
  expectedVsActual = [pscustomobject]@{ expectedPresent=(-not [string]::IsNullOrWhiteSpace($expected)); actualPresent=(-not [string]::IsNullOrWhiteSpace($ActualResult)); weakTermMatch=$matched; decision=$Decision }
  gaps = @($gaps)
  candidateSignals = @($gaps | ForEach-Object { [pscustomobject]@{ candidateType='logic_breakpoint'; breakpointKind=if($_.code -like '*expected*'){'hypothesis_failed_or_unproven'}else{'causal_review_gap'}; severity=$_.severity; code=$_.code; expectedInvariant='Every causal change plan should be reviewed against actual evidence before becoming a durable lesson or completion claim.'; observedViolation=$_.evidence; evidence=@('last-causal-change-review.json') } })
  guard = 'Expected optimization must be checked against actual evidence; choose keep, revise, or rollback instead of silently claiming success.'
  nextAction = if($gaps.Count -gt 0){'Fill actual evidence and choose keep/revise/rollback before completion or learning promotion.'}else{'Use this review as evidence for task verification and reflection promotion.'}
  path = $reviewPath
}
Write-JsonUtf8NoBom $reviewPath $result 12
Write-JsonUtf8NoBom $outPath $result 12
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "CAUSAL_CHANGE_REVIEW ok=$($result.ok) decision=$Decision gaps=$(@($gaps).Count) path=$reviewPath" }
if (-not $result.ok) { exit 1 }
exit 0
