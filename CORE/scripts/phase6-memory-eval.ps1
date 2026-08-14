[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Seal','PrepareAnswerInput','ValidateAnswerInput','Run','Aggregate','SelfTest')]
  [string]$Action = 'SelfTest',
  [string]$SourcePath = '',
  [string]$SealedPath = '',
  [string]$OutputPath = '',
  [string]$AnswerArtifactPath = '',
  [string]$AnswerInputPath = '',
  [string]$ConsumedMarkerPath = '',
  [string[]]$ReportPaths = @(),
  [switch]$Consume,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Root 'runtime\phase6_memory_eval.py'

function Require-Value([string]$Value, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Value)) { throw "PHASE6_ARGUMENT_REQUIRED: $Name is required for $Action." }
  return [IO.Path]::GetFullPath($Value)
}

if (-not (Test-Path -LiteralPath $Runtime -PathType Leaf)) { throw 'PHASE6_RUNTIME_MISSING: runtime\phase6_memory_eval.py is missing.' }
$arguments = @($Runtime)
switch ($Action) {
  'Seal' {
    $arguments += @('seal','--source',(Require-Value $SourcePath 'SourcePath'),'--output',(Require-Value $OutputPath 'OutputPath'))
  }
  'PrepareAnswerInput' {
    $arguments += @('prepare-answer-input','--sealed',(Require-Value $SealedPath 'SealedPath'),'--output',(Require-Value $OutputPath 'OutputPath'))
  }
  'ValidateAnswerInput' {
    $arguments += @('validate-answer-input','--answer-input',(Require-Value $AnswerInputPath 'AnswerInputPath'))
  }
  'Run' {
    $arguments += @('run','--sealed',(Require-Value $SealedPath 'SealedPath'),'--output',(Require-Value $OutputPath 'OutputPath'))
    if (-not [string]::IsNullOrWhiteSpace($AnswerArtifactPath)) { $arguments += @('--answer-artifact',[IO.Path]::GetFullPath($AnswerArtifactPath)) }
    if (-not [string]::IsNullOrWhiteSpace($AnswerInputPath)) { $arguments += @('--answer-input',[IO.Path]::GetFullPath($AnswerInputPath)) }
    if ($Consume) { $arguments += '--consume' }
    if (-not [string]::IsNullOrWhiteSpace($ConsumedMarkerPath)) { $arguments += @('--consumed-marker',[IO.Path]::GetFullPath($ConsumedMarkerPath)) }
  }
  'Aggregate' {
    if (@($ReportPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -lt 2) { throw 'PHASE6_ARGUMENT_REQUIRED: Aggregate requires at least two ReportPaths.' }
    $arguments += @('aggregate','--reports')
    $arguments += @($ReportPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $arguments += @('--output',(Require-Value $OutputPath 'OutputPath'))
  }
  default { $arguments += 'self-test' }
}

$raw = @(& python @arguments 2>&1)
$exitCode = $LASTEXITCODE
$text = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
if ([string]::IsNullOrWhiteSpace($text)) { throw 'PHASE6_RUNTIME_NO_OUTPUT: evaluator returned no result.' }
try { $result = $text | ConvertFrom-Json } catch { throw 'PHASE6_RUNTIME_INVALID_OUTPUT: evaluator returned invalid JSON.' }
if ($Json) { $result | ConvertTo-Json -Depth 20 }
elseif ($result.ok -eq $true) {
  if ($Action -eq 'Seal') { Write-Host "PHASE6_HOLDOUT_SEALED cases=$($result.caseCount) hash=$($result.setHash)" }
  elseif ($Action -eq 'PrepareAnswerInput') { Write-Host "PHASE6_ANSWER_INPUT_READY cases=$($result.caseCount) hash=$($result.inputHash) private=true" }
  elseif ($Action -eq 'ValidateAnswerInput') { Write-Host "PHASE6_ANSWER_INPUT_VALID cases=$($result.caseCount) hash=$($result.inputHash) private=true" }
  elseif ($Action -eq 'Run') { Write-Host "PHASE6_E2E_RUN status=$($result.status) recall4=$($result.overall.recallAt4) recall10=$($result.overall.recallAt10) output=$OutputPath" }
  elseif ($Action -eq 'Aggregate') { Write-Host "PHASE6_E2E_AGGREGATE fresh=$($result.fresh) twoFreshE2E=$($result.twoFreshSealedE2EAtLeast90) output=$OutputPath" }
  else { Write-Host "PHASE6_E2E_SELF_TEST status=$($result.status) ok=$($result.ok)" }
} else { Write-Host "PHASE6_E2E_FAILED code=$($result.code)" }
exit $exitCode
