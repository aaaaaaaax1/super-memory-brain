param(
  [ValidateSet('Create','Status','List')]
  [string]$Action = 'Status',
  [string]$ObservedProblem = '',
  [string]$RootCause = '',
  [string[]]$KnownFacts = @(),
  [string[]]$PriorChanges = @(),
  [string]$ProposedChange = '',
  [string]$ExpectedOptimization = '',
  [string]$VerificationMethod = '',
  [string[]]$Risks = @(),
  [string]$TaskId = '',
  [string]$RelatedGoalHash = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$planRoot = Join-Path $workspace 'change-causality'
$scopeRoot = Join-Path $workspace 'guard-state'
$taskPlanRoot = Join-Path $scopeRoot 'change-causality'
foreach ($dir in @($planRoot,$taskPlanRoot)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
$outPath = Join-Path $workspace 'last-causal-change-plan.json'

function Limit-Text([string]$Value, [int]$Max = 500) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '\s+', ' '
  if ($v.Length -gt $Max) { return $v.Substring(0, $Max) + '...' }
  return $v
}
function Safe-Name([string]$Value) {
  $v = if ([string]::IsNullOrWhiteSpace($Value)) { 'change-plan' } else { $Value }
  $safe = (($v -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { return 'change-plan' }
  if ($safe.Length -gt 36) { return $safe.Substring(0,36) }
  return $safe
}
function Safe-TaskId([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $safe = (($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { return '' }
  if ($safe.Length -gt 120) { return $safe.Substring(0,120) }
  return $safe
}
function Get-TaskPlanRoot([string]$Value) {
  $safe = Safe-TaskId $Value
  if ([string]::IsNullOrWhiteSpace($safe)) { return $planRoot }
  $dir = Join-Path $taskPlanRoot $safe
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  return $dir
}
function Get-Hash([string]$Raw) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Raw))[0..7] | ForEach-Object { $_.ToString('x2') })
}
function Add-Gap($List, [string]$Code, [string]$Evidence, [string]$Severity = 'medium') {
  [void]$List.Add([pscustomobject]@{ code=$Code; severity=$Severity; evidence=Limit-Text $Evidence 420 })
}

if ($Action -eq 'List') {
  $listRoot = Get-TaskPlanRoot $TaskId
  $items = @()
  foreach ($p in @(Get-ChildItem -LiteralPath $listRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 30)) {
    try {
      $o = Get-Content -LiteralPath $p.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $items += [pscustomobject]@{ planId=$o.planId; ok=$o.ok; observedProblem=$o.observedProblem; rootCause=$o.rootCause; proposedChange=$o.proposedChange; checkedAt=$o.checkedAt; path=$p.FullName }
    } catch {}
  }
  $result = [pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.causal-change-plan.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; taskId=Limit-Text $TaskId 120; count=@($items).Count; items=@($items); guard='Causal change plans make implementation changes traceable from problem cause to expected optimization and verification evidence.'; path=$outPath }
  Write-JsonUtf8NoBom $outPath $result 10
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "CAUSAL_CHANGE_PLAN count=$(@($items).Count) path=$outPath" }
  exit 0
}

if ($Action -eq 'Status') {
  $listRoot = Get-TaskPlanRoot $TaskId
  $latest = Get-ChildItem -LiteralPath $listRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $obj = if ($latest) { try { Get-Content -LiteralPath $latest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } else { $null }
  $result = [pscustomobject]@{ ok=($null -ne $obj); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.causal-change-plan.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; taskId=Limit-Text $TaskId 120; latest=$obj; guard='Before meaningful mutation, explain observed problem, root cause, known facts, prior changes, intervention, expected optimization, verification, and risk.'; path=if($latest){$latest.FullName}else{$listRoot} }
  Write-JsonUtf8NoBom $outPath $result 12
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "CAUSAL_CHANGE_PLAN ok=$($result.ok) path=$($result.path)" }
  if (-not $result.ok) { exit 1 }
  exit 0
}

$gaps = New-Object System.Collections.ArrayList
if ([string]::IsNullOrWhiteSpace($ObservedProblem)) { Add-Gap $gaps 'missing_observed_problem' 'ObservedProblem is required to prevent random patching.' 'high' }
if ([string]::IsNullOrWhiteSpace($RootCause)) { Add-Gap $gaps 'missing_root_cause' 'RootCause is required to connect changes to causes.' 'high' }
if (@($KnownFacts).Count -eq 0) { Add-Gap $gaps 'missing_known_facts' 'KnownFacts should capture what is already proven by live evidence or prior changes.' }
if ([string]::IsNullOrWhiteSpace($ProposedChange)) { Add-Gap $gaps 'missing_proposed_change' 'ProposedChange is required.' 'high' }
if ([string]::IsNullOrWhiteSpace($ExpectedOptimization)) { Add-Gap $gaps 'missing_expected_optimization' 'ExpectedOptimization is required so the change has a measurable outcome.' 'high' }
if ([string]::IsNullOrWhiteSpace($VerificationMethod)) { Add-Gap $gaps 'missing_verification_method' 'VerificationMethod is required to avoid claiming improvement without evidence.' 'high' }

$raw = ($ObservedProblem,$RootCause,($KnownFacts -join '|'),($PriorChanges -join '|'),$ProposedChange,$ExpectedOptimization,$VerificationMethod,($Risks -join '|'),$TaskId,$RelatedGoalHash) -join '||'
$hash = Get-Hash $raw
$fileName = (Safe-Name $ObservedProblem) + '-' + $hash + '.json'
$writeRoot = Get-TaskPlanRoot $TaskId
$path = Join-Path $writeRoot $fileName
$result = [pscustomobject]@{
  ok = ($gaps.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.causal-change-plan.v1'
  version = (Get-SuperBrainManifest $Root).version
  action = $Action
  planId = $hash
  taskId = Limit-Text $TaskId 120
  relatedGoalHash = Limit-Text $RelatedGoalHash 120
  observedProblem = Limit-Text $ObservedProblem 700
  rootCause = Limit-Text $RootCause 700
  knownFacts = @($KnownFacts | ForEach-Object { Limit-Text $_ 360 })
  priorChanges = @($PriorChanges | ForEach-Object { Limit-Text $_ 360 })
  proposedChange = Limit-Text $ProposedChange 700
  expectedOptimization = Limit-Text $ExpectedOptimization 700
  verificationMethod = Limit-Text $VerificationMethod 700
  risks = @($Risks | ForEach-Object { Limit-Text $_ 360 })
  reasoningFrame = [pscustomobject]@{
    rootCauseAnalysis = 'Separate symptoms from root/contributing causes, then add recurrence prevention rather than one-off patches.'
    theoryOfChange = 'Map desired outcome backward through causal assumptions and define indicators that prove the change worked.'
    systemsThinking = 'Check interactions, feedback loops, leverage points, and unintended consequences before changing structure.'
    trace = 'observed problem -> root cause -> known/prior facts -> intervention -> expected optimization -> verification -> residual risk'
  }
  gaps = @($gaps)
  candidateSignals = @($gaps | ForEach-Object { [pscustomobject]@{ candidateType='gap'; gapKind='causal_change_plan'; severity=$_.severity; code=$_.code; expectedInvariant='Meaningful changes should be causally traceable and verifiable.'; observedViolation=$_.evidence; evidence=@('last-causal-change-plan.json') } })
  guard = 'Do not patch randomly: every meaningful change should name the cause, expected outcome, already-known prior changes, verification method, and residual risk.'
  nextAction = if ($gaps.Count -gt 0) { 'Fill missing causal fields before mutation or completion.' } else { 'Proceed with the proposed change, then verify using the stated method and update route/integration checkpoints.' }
  path = $path
}
Write-JsonUtf8NoBom $path $result 12
Write-JsonUtf8NoBom $outPath $result 12
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "CAUSAL_CHANGE_PLAN ok=$($result.ok) gaps=$(@($gaps).Count) planId=$hash path=$path" }
if (-not $result.ok) { exit 1 }
exit 0
