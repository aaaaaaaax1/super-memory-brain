[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Create','Status','List','AssessIntervention')]
  [string]$Action = 'Status',
  [string]$TaskId = '',
  [string]$Problem = '',
  [string]$PainPoint = '',
  [string]$Objective = '',
  [string[]]$Facts = @(),
  [string[]]$FactEvidence = @(),
  [string[]]$Assumptions = @(),
  [string[]]$Unknowns = @(),
  [string[]]$CriticalUnknowns = @(),
  [ValidateSet('verified','hypothesis','unknown')]
  [string]$RootCauseStatus = 'unknown',
  [string]$RootCause = '',
  [string]$RootCauseEvidence = '',
  [string[]]$Constraints = @(),
  [string[]]$Options = @(),
  [string[]]$Tradeoffs = @(),
  [string[]]$Criteria = @(),
  [string]$SelectedOption = '',
  [string]$DecisionClaim = '',
  [switch]$ClaimsOptimal,
  [string]$DiscriminatingTest = '',
  [string]$DiscriminatingTestEvidence = '',
  [string[]]$ExecutionSteps = @(),
  [string[]]$StepInputs = @(),
  [string[]]$StepOutputs = @(),
  [string[]]$StepAcceptance = @(),
  [string[]]$StepStopConditions = @(),
  [string[]]$AcceptanceCriteria = @(),
  [string[]]$Risks = @(),
  [ValidateSet('none','marginal','material')]
  [string]$ExpectedBenefitLevel = 'none',
  [ValidateSet('none','low','material','high')]
  [string]$RiskLevel = 'none',
  [ValidateSet('none','inference','verified')]
  [string]$EvidenceStrength = 'none',
  [string]$ExpectedDelta = '',
  [string]$Recommendation = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$scopeRoot = Join-Path $workspace 'guard-state'
$decisionRoot = Join-Path $scopeRoot 'engineering-decisions'
foreach ($dir in @($workspace,$scopeRoot,$decisionRoot)) {
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}
$outPath = Join-Path $workspace 'last-engineering-decision-gate.json'

function Limit-Text([string]$Value,[int]$Max=700) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = $Value.Trim() -replace '\s+',' '
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}
function Safe-Name([string]$Value) {
  $safe = (($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'engineering-decision' }
  if ($safe.Length -gt 36) { $safe = $safe.Substring(0,36) }
  return $safe
}
function Safe-TaskId([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $safe = (($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ($safe.Length -gt 120) { $safe = $safe.Substring(0,120) }
  return $safe
}
function Get-DecisionDirectory([string]$Value) {
  $safe = Safe-TaskId $Value
  if ([string]::IsNullOrWhiteSpace($safe)) { return $decisionRoot }
  $path = Join-Path $decisionRoot $safe
  if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
  return $path
}
function Get-ShortHash([string]$Value) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))[0..7] | ForEach-Object { $_.ToString('x2') })
  } finally { $sha.Dispose() }
}
function Add-Gap($List,[string]$Code,[string]$Evidence,[string]$Severity='medium') {
  [void]$List.Add([pscustomobject]@{ code=$Code; severity=$Severity; evidence=Limit-Text $Evidence 420 })
}
function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
function Test-OptimalLanguage([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  if ($Value -match '(?i)\b(optimal|best|best option|globally optimal)\b') { return $true }
  foreach ($term in @((U @(26368,20248)),(U @(26368,20339)))) {
    if ($Value.Contains($term)) { return $true }
  }
  return $false
}
function Get-LatestDecision([string]$Value) {
  $dir = Get-DecisionDirectory $Value
  $latest = Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $latest) { return $null }
  try { return Get-Content -LiteralPath $latest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

if ($Action -eq 'AssessIntervention') {
  $materialBenefit = ($ExpectedBenefitLevel -eq 'material')
  $materialRisk = ($RiskLevel -in @('material','high'))
  $grounded = ($EvidenceStrength -in @('inference','verified'))
  $highUnknownRisk = ($RiskLevel -eq 'high' -and -not $grounded)
  $shouldIntervene = (($materialBenefit -or $materialRisk) -and $grounded) -or $highUnknownRisk
  $mode = if (-not $shouldIntervene) { 'silent' } elseif ($highUnknownRisk) { 'verify_or_contain' } else { 'recommend' }
  $reason = if ($mode -eq 'silent') {
    if ($materialBenefit -or $materialRisk) { 'material claim lacks a current evidence-backed inference' } else { 'expected benefit and risk are below the material threshold' }
  } elseif ($mode -eq 'verify_or_contain') {
    'high potential risk justifies verification or containment, but not a factual causal claim'
  } elseif ($materialRisk) {
    'material evidence-backed risk justifies proactive intervention'
  } else {
    'material evidence-backed expected benefit justifies proactive intervention'
  }
  $result = [pscustomobject]@{
    ok = $true
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    schema = 'super-brain.engineering-intervention-gate.v1'
    version = (Get-SuperBrainManifest $Root).version
    action = $Action
    shouldIntervene = $shouldIntervene
    mode = $mode
    expectedBenefitLevel = $ExpectedBenefitLevel
    riskLevel = $RiskLevel
    evidenceStrength = $EvidenceStrength
    evidence = @(Limit-Text (($FactEvidence + $Facts) -join '; ') 700)
    expectedDelta = Limit-Text $ExpectedDelta 500
    recommendation = Limit-Text $Recommendation 500
    reason = $reason
    guard = 'Marginal improvements stay silent. Material benefit/risk requires evidence-backed inference; unverified high risk may trigger only verify-or-contain action.'
  }
  Write-JsonUtf8NoBom $outPath $result 10
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "ENGINEERING_INTERVENTION_GATE intervene=$shouldIntervene mode=$mode reason=$reason" }
  exit 0
}

if ($Action -eq 'List') {
  $items = @()
  $dir = Get-DecisionDirectory $TaskId
  foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 30)) {
    try {
      $item = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $items += [pscustomobject]@{ decisionId=$item.decisionId; ok=$item.ok; taskId=$item.taskId; problem=$item.problem; selectedOption=$item.selectedOption; claimLevel=$item.optimality.claimLevel; checkedAt=$item.checkedAt; path=$file.FullName }
    } catch {}
  }
  $result = [pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.engineering-decision-gate.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; taskId=Limit-Text $TaskId 120; count=@($items).Count; items=@($items); path=$dir }
  Write-JsonUtf8NoBom $outPath $result 12
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "ENGINEERING_DECISION_GATE action=List count=$(@($items).Count) path=$dir" }
  exit 0
}

if ($Action -eq 'Status') {
  $latest = Get-LatestDecision $TaskId
  $result = [pscustomobject]@{ ok=($null -ne $latest -and $latest.ok -eq $true); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.engineering-decision-gate.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; taskId=Limit-Text $TaskId 120; latest=$latest; guard='A valid engineering decision keeps facts, inferences, unknowns, root-cause confidence, option tradeoffs, execution contracts, and acceptance evidence explicit.'; path=if($latest){$latest.path}else{(Get-DecisionDirectory $TaskId)} }
  Write-JsonUtf8NoBom $outPath $result 16
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "ENGINEERING_DECISION_GATE action=Status ok=$($result.ok) path=$($result.path)" }
  if (-not $result.ok) { exit 1 }
  exit 0
}

$gaps = New-Object System.Collections.ArrayList
if ([string]::IsNullOrWhiteSpace($Problem)) { Add-Gap $gaps 'missing_problem' 'Problem is required.' 'high' }
if ([string]::IsNullOrWhiteSpace($PainPoint)) { Add-Gap $gaps 'missing_pain_point' 'PainPoint must identify the costly failure or bottleneck.' 'high' }
if ([string]::IsNullOrWhiteSpace($Objective)) { Add-Gap $gaps 'missing_objective' 'Objective or cost function is required.' 'high' }

$factRecords = New-Object System.Collections.ArrayList
$factCount = @($Facts).Count
$evidenceCount = @($FactEvidence).Count
if ($factCount -eq 0) { Add-Gap $gaps 'missing_facts' 'At least one current evidence-backed fact is required.' 'high' }
if ($factCount -ne $evidenceCount) { Add-Gap $gaps 'fact_evidence_count_mismatch' "facts=$factCount evidence=$evidenceCount" 'high' }
for ($index=0; $index -lt $factCount; $index++) {
  $claim = Limit-Text ([string]$Facts[$index]) 500
  $evidence = if ($index -lt $evidenceCount) { Limit-Text ([string]$FactEvidence[$index]) 500 } else { '' }
  if ([string]::IsNullOrWhiteSpace($claim)) { Add-Gap $gaps 'empty_fact' "factIndex=$index" 'high' }
  if ([string]::IsNullOrWhiteSpace($evidence)) { Add-Gap $gaps 'fact_without_evidence' "factIndex=$index claim=$claim" 'high' }
  [void]$factRecords.Add([pscustomobject]@{ class='FACT'; claim=$claim; evidence=$evidence })
}

if ([string]::IsNullOrWhiteSpace($RootCause)) { Add-Gap $gaps 'missing_root_cause_statement' 'State the root cause as verified, hypothesis, or unknown.' 'high' }
if ($RootCauseStatus -eq 'verified' -and [string]::IsNullOrWhiteSpace($RootCauseEvidence)) { Add-Gap $gaps 'verified_root_cause_without_evidence' 'A verified root cause requires direct evidence.' 'high' }
if ($RootCauseStatus -eq 'hypothesis' -and [string]::IsNullOrWhiteSpace($DiscriminatingTest)) { Add-Gap $gaps 'untested_root_cause_hypothesis' 'A root-cause hypothesis requires the cheapest discriminating test.' 'high' }
if ($RootCauseStatus -eq 'unknown' -and [string]::IsNullOrWhiteSpace($DiscriminatingTest)) { Add-Gap $gaps 'unknown_root_cause_without_test' 'Unknown root cause requires a discriminating test before causal certainty.' 'high' }

foreach ($critical in @($CriticalUnknowns)) {
  if ([string]::IsNullOrWhiteSpace([string]$critical)) { continue }
  if (@($Unknowns | Where-Object { [string]$_ -eq [string]$critical }).Count -eq 0) { Add-Gap $gaps 'critical_unknown_not_declared' "criticalUnknown=$critical" }
}
if (@($CriticalUnknowns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0 -and [string]::IsNullOrWhiteSpace($DiscriminatingTest)) { Add-Gap $gaps 'untested_critical_unknown' 'Critical unknowns require the cheapest discriminating test.' 'high' }

if (@($Constraints | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { Add-Gap $gaps 'missing_constraints' 'At least one decision constraint is required.' 'high' }
if (@($Options | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -lt 2) { Add-Gap $gaps 'insufficient_options' 'Compare at least two feasible options.' 'high' }
if (@($Tradeoffs).Count -ne @($Options).Count) { Add-Gap $gaps 'option_tradeoff_count_mismatch' "options=$(@($Options).Count) tradeoffs=$(@($Tradeoffs).Count)" 'high' }
if (@($Criteria | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { Add-Gap $gaps 'missing_decision_criteria' 'Decision criteria are required.' 'high' }
if ([string]::IsNullOrWhiteSpace($SelectedOption)) { Add-Gap $gaps 'missing_selected_option' 'SelectedOption is required.' 'high' }
elseif (@($Options | Where-Object { [string]$_ -eq $SelectedOption }).Count -eq 0) { Add-Gap $gaps 'selected_option_not_feasible' 'SelectedOption must exactly match one listed option.' 'high' }

$stepCount = @($ExecutionSteps).Count
if ($stepCount -eq 0) { Add-Gap $gaps 'missing_execution_chain' 'At least one dependency-ordered execution step is required.' 'high' }
$stepArrays = @($StepInputs,$StepOutputs,$StepAcceptance,$StepStopConditions)
foreach ($array in $stepArrays) {
  if (@($array).Count -ne $stepCount) { Add-Gap $gaps 'execution_step_contract_count_mismatch' "steps=$stepCount contractItems=$(@($array).Count)" 'high' }
}
$executionChain = New-Object System.Collections.ArrayList
for ($index=0; $index -lt $stepCount; $index++) {
  $inputValue = if ($index -lt @($StepInputs).Count) { Limit-Text ([string]$StepInputs[$index]) 400 } else { '' }
  $outputValue = if ($index -lt @($StepOutputs).Count) { Limit-Text ([string]$StepOutputs[$index]) 400 } else { '' }
  $acceptValue = if ($index -lt @($StepAcceptance).Count) { Limit-Text ([string]$StepAcceptance[$index]) 400 } else { '' }
  $stopValue = if ($index -lt @($StepStopConditions).Count) { Limit-Text ([string]$StepStopConditions[$index]) 400 } else { '' }
  if ([string]::IsNullOrWhiteSpace($inputValue) -or [string]::IsNullOrWhiteSpace($outputValue) -or [string]::IsNullOrWhiteSpace($acceptValue) -or [string]::IsNullOrWhiteSpace($stopValue)) { Add-Gap $gaps 'execution_step_without_contract' "stepIndex=$index" 'high' }
  [void]$executionChain.Add([pscustomobject]@{ order=($index+1); action=Limit-Text ([string]$ExecutionSteps[$index]) 500; input=$inputValue; output=$outputValue; acceptance=$acceptValue; stopCondition=$stopValue })
}
if (@($AcceptanceCriteria | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { Add-Gap $gaps 'missing_final_acceptance' 'Final acceptance criteria are required.' 'high' }
if (@($Risks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { Add-Gap $gaps 'missing_residual_risk' 'Residual risk must be explicit.' }

$optimalClaimed = ([bool]$ClaimsOptimal -or (Test-OptimalLanguage (($DecisionClaim,$SelectedOption) -join ' ')))
$optimalPrerequisiteCodes = @('missing_objective','missing_constraints','insufficient_options','option_tradeoff_count_mismatch','missing_decision_criteria','missing_selected_option','selected_option_not_feasible','missing_facts','fact_evidence_count_mismatch','fact_without_evidence')
$optimalPrerequisitesOk = (@($gaps | Where-Object { $optimalPrerequisiteCodes -contains [string]$_.code }).Count -eq 0)
$criticalResolutionNeeded = (@($CriticalUnknowns).Count -gt 0 -or $RootCauseStatus -in @('hypothesis','unknown'))
$criticalResolutionOk = (-not $criticalResolutionNeeded -or -not [string]::IsNullOrWhiteSpace($DiscriminatingTestEvidence))
if ($optimalClaimed -and (-not $optimalPrerequisitesOk -or -not $criticalResolutionOk)) {
  Add-Gap $gaps 'unsupported_optimal_claim' 'Best/optimal requires objective, constraints, alternatives, tradeoffs, criteria, evidence-backed facts, and resolution evidence for decision-changing unknowns.' 'high'
}

$raw = @($Problem,$PainPoint,$Objective,($Facts -join '|'),($FactEvidence -join '|'),($Assumptions -join '|'),($Unknowns -join '|'),($CriticalUnknowns -join '|'),$RootCauseStatus,$RootCause,$RootCauseEvidence,($Constraints -join '|'),($Options -join '|'),($Tradeoffs -join '|'),($Criteria -join '|'),$SelectedOption,$DecisionClaim,[bool]$ClaimsOptimal,$DiscriminatingTest,$DiscriminatingTestEvidence,($ExecutionSteps -join '|'),($AcceptanceCriteria -join '|'),($Risks -join '|'),$TaskId) -join '||'
$decisionId = Get-ShortHash $raw
$writeDir = Get-DecisionDirectory $TaskId
$path = Join-Path $writeDir ((Safe-Name $Problem) + '-' + $decisionId + '.json')
$result = [pscustomobject]@{
  ok = ($gaps.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.engineering-decision-gate.v1'
  version = (Get-SuperBrainManifest $Root).version
  action = $Action
  decisionId = $decisionId
  taskId = Limit-Text $TaskId 120
  problem = Limit-Text $Problem 800
  painPoint = Limit-Text $PainPoint 700
  objective = Limit-Text $Objective 700
  epistemicGrounding = [pscustomobject]@{
    facts = @($factRecords)
    inferences = @($Assumptions | ForEach-Object { [pscustomobject]@{ class='INFERENCE'; claim=Limit-Text ([string]$_) 500 } })
    unknowns = @($Unknowns | ForEach-Object { [pscustomobject]@{ class='UNKNOWN'; claim=Limit-Text ([string]$_) 500; critical=(@($CriticalUnknowns) -contains [string]$_) } })
    factsSupported = (@($gaps | Where-Object { [string]$_.code -in @('missing_facts','fact_evidence_count_mismatch','empty_fact','fact_without_evidence') }).Count -eq 0)
    liveEvidenceOverridesMemory = $true
  }
  rootCause = [pscustomobject]@{ statement=Limit-Text $RootCause 700; status=$RootCauseStatus; evidence=Limit-Text $RootCauseEvidence 700; discriminatingTest=Limit-Text $DiscriminatingTest 700; discriminatingTestEvidence=Limit-Text $DiscriminatingTestEvidence 700 }
  constraints = @($Constraints | ForEach-Object { Limit-Text ([string]$_) 400 })
  options = @(for($index=0; $index -lt @($Options).Count; $index++){ [pscustomobject]@{ option=Limit-Text ([string]$Options[$index]) 500; tradeoff=if($index -lt @($Tradeoffs).Count){Limit-Text ([string]$Tradeoffs[$index]) 500}else{''}; selected=([string]$Options[$index] -eq $SelectedOption) } })
  criteria = @($Criteria | ForEach-Object { Limit-Text ([string]$_) 400 })
  selectedOption = Limit-Text $SelectedOption 600
  decisionClaim = Limit-Text $DecisionClaim 700
  optimality = [pscustomobject]@{ claimed=$optimalClaimed; qualified=(-not $optimalClaimed -or ($optimalPrerequisitesOk -and $criticalResolutionOk)); claimLevel=if($optimalClaimed -and $optimalPrerequisitesOk -and $criticalResolutionOk){'best_under_stated_objective_and_constraints'}else{'recommended_under_current_evidence'}; guard='Optimal is conditional on the stated objective, constraints, alternatives, tradeoffs, criteria, and resolved decision-changing unknowns; it is never universal.' }
  executionChain = @($executionChain)
  acceptanceCriteria = @($AcceptanceCriteria | ForEach-Object { Limit-Text ([string]$_) 500 })
  risks = @($Risks | ForEach-Object { Limit-Text ([string]$_) 500 })
  gaps = @($gaps)
  candidateSignals = @($gaps | ForEach-Object { [pscustomobject]@{ candidateType='gap'; gapKind='engineering_judgment'; severity=$_.severity; code=$_.code; expectedInvariant='Engineering claims must remain inside current evidence and execution must be dependency-ordered and verifiable.'; observedViolation=$_.evidence; evidence=@('last-engineering-decision-gate.json') } })
  outputContract = @('Judgment','Evidence','Best option','Execution chain','Acceptance/Risk')
  guard = 'FACT requires evidence; root-cause confidence is explicit; critical unknowns require discriminating tests; optimality requires objective, constraints, alternatives, tradeoffs, criteria, and resolution evidence.'
  nextAction = if($gaps.Count -gt 0){'Resolve the listed evidence/decision gaps and recreate the engineering decision before meaningful mutation or completion.'}else{'Proceed step by step; stop on any failed acceptance or stop condition, then update the evidence model before continuing.'}
  path = $path
}
Write-JsonUtf8NoBom $path $result 18
Write-JsonUtf8NoBom $outPath $result 18
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "ENGINEERING_DECISION_GATE action=Create ok=$($result.ok) gaps=$(@($result.gaps).Count) decisionId=$decisionId path=$path" }
if (-not $result.ok) { exit 1 }
exit 0
