param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [string]$Query = '',
  [string]$Scope = '',
  [string]$TaskId = '',
  [ValidateSet('BeforeAct','BeforeMutation','BeforeCompletion','AfterUserCorrection','Status')]
  [string]$Phase = 'BeforeAct',
  [int]$MaxAgeMinutes = 60,
  [switch]$AllowMissingPreflight,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$outPath = Join-Path $workspace 'last-cognitive-enforce.json'
$inputText = if (-not [string]::IsNullOrWhiteSpace($Query)) { $Query } else { (($Text -join ' ').Trim()) }
if ([string]::IsNullOrWhiteSpace($inputText)) { $inputText = 'general task' }

function Limit-Text([string]$Value, [int]$Max = 240) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '\s+', ' '
  if ($v.Length -gt $Max) { return $v.Substring(0, $Max) + '...' }
  return $v
}

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Add-Check([System.Collections.ArrayList]$Checks, [string]$Name, [bool]$Ok, [string]$Evidence, [bool]$Required = $true) {
  [void]$Checks.Add([pscustomobject]@{ name=$Name; ok=$Ok; required=$Required; evidence=Limit-Text $Evidence 360 })
}

function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
$lower = $inputText.ToLowerInvariant()
$zhSubAgent = (U @(23376)) + 'agent'
$zhChannel = U @(36890,36947)

function Test-EngineeringJudgmentIntent([string]$IntentName) {
  if ($IntentName -eq 'add_or_optimize_feature') { return $true }
  foreach ($term in @('fix','debug','repair','optimize','optimization','architecture','architect','root cause','tradeoff','trade-off','best option','optimal','performance','bottleneck','regression','refactor','migration','failure analysis')) {
    if ($lower.Contains($term)) { return $true }
  }
  foreach ($term in @((U @(20462,22797)),(U @(20248,21270)),(U @(26550,26500)),(U @(26681,22240)),(U @(26368,20248)),(U @(26368,20339)),(U @(24615,33021)),(U @(37325,26500)),(U @(25925,38556)),(U @(35774,35745)),(U @(20915,31574)))) {
    if ($inputText.Contains($term)) { return $true }
  }
  return $false
}

$intent = $null
try {
  $intentRaw = @(& (Join-Path $PSScriptRoot 'intent-router.ps1') $inputText -Json 2>$null)
  if ($intentRaw) { $intent = (($intentRaw -join "`n") | ConvertFrom-Json) }
} catch {}
$intentName = if ($intent -and $intent.intent) { [string]$intent.intent } else { 'general_task' }
$engineeringRequiredFromInput = Test-EngineeringJudgmentIntent $intentName

$highRiskReasons = New-Object System.Collections.ArrayList
if ($intentName -eq 'agent_bridge_channel' -or $lower.Contains('agent bridge') -or ($lower.Contains('agent') -and ($inputText.Contains($zhChannel) -or $inputText.Contains($zhSubAgent)))) { [void]$highRiskReasons.Add('agent_bridge_channel') }
if ($engineeringRequiredFromInput) { [void]$highRiskReasons.Add('engineering_judgment') }
foreach ($term in @('memory mechanism','cognitive','preflight','startup','global route','hot-refresh','version bump','release','historical import','destructive','apply','force','delete','remove','overwrite')) {
  if ($lower.Contains($term)) { [void]$highRiskReasons.Add($term.Replace(' ','_')) }
}
foreach ($term in @((U @(35760,24518)),(U @(20840,23616)),(U @(36335,30001)),(U @(21457,24067)),(U @(21382,21490)),(U @(21024,38500)))) {
  if ($inputText.Contains($term)) { [void]$highRiskReasons.Add('cjk_high_risk') }
}
$isHighRisk = ($highRiskReasons.Count -gt 0)

$preflight = Read-WorkspaceJson 'last-cognitive-preflight.json'
$checks = New-Object System.Collections.ArrayList
$violations = New-Object System.Collections.ArrayList
$blockers = New-Object System.Collections.ArrayList

$preflightExists = ($null -ne $preflight)
$preflightExistsEvidence = if ($preflightExists) { "path=last-cognitive-preflight.json checkedAt=$($preflight.checkedAt)" } else { 'missing last-cognitive-preflight.json' }
Add-Check $checks 'cognitive-preflight-exists' ($preflightExists -or -not $isHighRisk -or $AllowMissingPreflight) $preflightExistsEvidence $isHighRisk

$preflightQueryMatch = ($preflightExists -and [string]$preflight.query -eq (Limit-Text $inputText 260))
$preflightQueryEvidence = if ($preflightExists) { "expected=$(Limit-Text $inputText 260) observed=$($preflight.query)" } else { 'missing preflight' }
Add-Check $checks 'cognitive-preflight-query-match' ($preflightQueryMatch -or -not $isHighRisk -or $AllowMissingPreflight) $preflightQueryEvidence $isHighRisk

$preflightFresh = $false
if ($preflightExists -and $preflight.checkedAt) {
  try {
    $age = ((Get-Date) - [datetime]::Parse([string]$preflight.checkedAt)).TotalMinutes
    $preflightFresh = ($age -le $MaxAgeMinutes)
  } catch { $preflightFresh = $false }
}
$preflightFreshEvidence = if ($preflightExists) { "maxAgeMinutes=$MaxAgeMinutes checkedAt=$($preflight.checkedAt)" } else { 'no preflight to age-check' }
Add-Check $checks 'cognitive-preflight-fresh' ($preflightFresh -or -not $isHighRisk -or $AllowMissingPreflight) $preflightFreshEvidence $isHighRisk

$modeOk = ($preflightExists -and [string]$preflight.cognitiveMode -eq 'memory_driven_execution_control')
$modeEvidence = if ($preflightExists) { "cognitiveMode=$($preflight.cognitiveMode)" } else { 'missing preflight' }
Add-Check $checks 'memory-driven-mode' ($modeOk -or -not $isHighRisk -or $AllowMissingPreflight) $modeEvidence $isHighRisk

$mustCount = if ($preflightExists) { @($preflight.mustPreserve).Count } else { 0 }
$guardCount = if ($preflightExists) { @($preflight.driftGuards).Count } else { 0 }
Add-Check $checks 'must-preserve-present' ($mustCount -gt 0 -or -not $isHighRisk -or $AllowMissingPreflight) "mustPreserve=$mustCount" $isHighRisk
Add-Check $checks 'drift-guards-present' ($guardCount -gt 0 -or -not $isHighRisk -or $AllowMissingPreflight) "driftGuards=$guardCount" $isHighRisk

$engineeringRequired = ($engineeringRequiredFromInput -or ($preflightExists -and $preflightQueryMatch -and $preflight.engineeringJudgment.required -eq $true))
$engineeringContractPresent = ($preflightExists -and $preflight.engineeringJudgment -and [string]$preflight.engineeringJudgment.decisionGate -eq 'engineering-decision-gate.ps1')
Add-Check $checks 'engineering-judgment-contract' ($engineeringContractPresent -or -not $engineeringRequired -or $AllowMissingPreflight) "required=$engineeringRequired decisionGate=$($preflight.engineeringJudgment.decisionGate)" $engineeringRequired

$currentTaskContext = Read-WorkspaceJson 'current-task-context.json'
if ([string]::IsNullOrWhiteSpace($TaskId) -and $currentTaskContext -and [string]$currentTaskContext.status -eq 'active') { $TaskId = [string]$currentTaskContext.taskId }
$engineeringGateRequired = ($engineeringRequired -and $Phase -in @('BeforeMutation','BeforeCompletion'))
$engineeringStatus = $null
if ($engineeringGateRequired) {
  try {
    $engineeringRaw = @(& (Join-Path $PSScriptRoot 'engineering-decision-gate.ps1') -Action Status -TaskId $TaskId -Json 2>$null)
    if ($engineeringRaw) { $engineeringStatus = (($engineeringRaw -join "`n") | ConvertFrom-Json) }
  } catch {}
}
$engineeringDecision = if($engineeringStatus -and $engineeringStatus.latest){$engineeringStatus.latest}else{$null}
$engineeringTaskMatch = ([string]::IsNullOrWhiteSpace($TaskId) -or ($engineeringDecision -and [string]$engineeringDecision.taskId -eq $TaskId))
$engineeringResolutionOk = (-not $engineeringDecision -or [string]$engineeringDecision.rootCause.status -eq 'verified' -or -not [string]::IsNullOrWhiteSpace([string]$engineeringDecision.rootCause.discriminatingTestEvidence))
$engineeringCompletionEvidenceOk = ($Phase -ne 'BeforeCompletion' -or $engineeringResolutionOk)
$engineeringGateOk = (-not $engineeringGateRequired -or ($engineeringStatus -and $engineeringStatus.ok -eq $true -and $engineeringDecision.ok -eq $true -and $engineeringDecision.epistemicGrounding.factsSupported -eq $true -and $engineeringCompletionEvidenceOk -and $engineeringTaskMatch))
$engineeringGateEvidence = 'not required before this phase'
if ($engineeringGateRequired) {
  $engineeringGateEvidence = if($engineeringDecision){"taskId=$($engineeringDecision.taskId) requiredTaskId=$TaskId decisionId=$($engineeringDecision.decisionId) rootCauseStatus=$($engineeringDecision.rootCause.status) completionEvidenceOk=$engineeringCompletionEvidenceOk gaps=$(@($engineeringDecision.gaps).Count)"}else{'missing valid task-scoped engineering decision'}
}
Add-Check $checks 'engineering-decision-gate' $engineeringGateOk $engineeringGateEvidence $engineeringGateRequired

if ($isHighRisk -and -not $AllowMissingPreflight) {
  foreach ($check in @($checks)) {
    if ($check.required -and $check.ok -ne $true) {
      [void]$violations.Add($check.name)
      [void]$blockers.Add("$($check.name): $($check.evidence)")
    }
  }
}

$result = [pscustomobject]@{
  ok = ($violations.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.cognitive-enforce.v1'
  version = (Get-SuperBrainManifest $Root).version
  query = Limit-Text $inputText 260
  intent = $intentName
  phase = $Phase
  required = $isHighRisk
  highRiskReasons = @($highRiskReasons | Select-Object -Unique)
  checks = @($checks)
  violations = @($violations)
  blockers = @($blockers)
  candidateSignals = @($violations | ForEach-Object { [pscustomobject]@{ candidateType='gap'; gapKind=if($_ -like '*engineering-decision*'){'missing_engineering_decision'}elseif($_ -like '*query-match*'){'stale_or_wrong_preflight'}elseif($_ -like '*fresh*'){'stale_state'}elseif($_ -like '*must*'){'missing_must_preserve'}elseif($_ -like '*drift*'){'missing_drift_guards'}else{'missing_preflight'}; severity='medium'; code=$_; expected=@('fresh query-matched cognitive-preflight','mustPreserve','driftGuards','valid engineering decision when required'); observed=@($_); missing=@($_); evidence=@('last-cognitive-enforce.json') } })
  mustPreserve = if ($preflightExists) { @($preflight.mustPreserve) } else { @() }
  driftGuards = if ($preflightExists) { @($preflight.driftGuards) } else { @() }
  engineeringJudgment = [pscustomobject]@{ required=$engineeringRequired; gateRequired=$engineeringGateRequired; gateOk=$engineeringGateOk; completionEvidenceOk=$engineeringCompletionEvidenceOk; taskId=$TaskId; decisionId=if($engineeringDecision){$engineeringDecision.decisionId}else{''}; epistemicClasses=@('FACT','INFERENCE','UNKNOWN') }
  guard = 'High-risk work must pass a fresh query-matched cognitive preflight; engineering mutation/completion must also pass evidence and decision grounding.'
  nextAction = if (@($violations) -contains 'engineering-decision-gate') { 'Create a valid task-scoped engineering decision with evidence, options, execution contracts, acceptance, and risk, then re-run cognitive-enforce.' } elseif ($violations.Count -gt 0) { 'Run scripts\cognitive-preflight.ps1 for the current command, then re-run cognitive-enforce before action.' } else { 'Proceed while applying mustPreserve and driftGuards; stop on failed engineering acceptance and run runtime-drift-checkpoint before major steps.' }
  path = $outPath
}

Write-JsonUtf8NoBom $outPath $result 10
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "COGNITIVE_ENFORCE ok=$($result.ok) required=$($result.required) intent=$($result.intent) violations=$(@($result.violations).Count) path=$outPath" }
if (-not $result.ok) { exit 1 }
exit 0
