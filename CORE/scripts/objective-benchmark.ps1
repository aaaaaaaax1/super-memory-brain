[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Plan','Evaluate')]
  [string]$Action = 'Plan',
  [string]$ResultsPath = '',
  [string]$PolicyPath = '',
  [string]$ReportPath = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PolicyPath)) { $PolicyPath = Join-Path $Root 'objective-benchmark-policy.json' }

function Read-Json([string]$Path,[string]$Code) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Code|required file missing" }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { throw "$Code|invalid json" }
}

function Get-WilsonInterval([int]$Passed,[int]$Total) {
  if ($Total -le 0) { return $null }
  $z = 1.95996398454005
  $z2 = $z * $z
  $p = $Passed / [double]$Total
  $denominator = 1.0 + ($z2 / $Total)
  $center = ($p + ($z2 / (2.0 * $Total))) / $denominator
  $margin = ($z * [Math]::Sqrt((($p * (1.0 - $p)) / $Total) + ($z2 / (4.0 * $Total * $Total)))) / $denominator
  return [pscustomobject]@{ lower=[Math]::Round([Math]::Max(0,$center-$margin),6); upper=[Math]::Round([Math]::Min(1,$center+$margin),6); confidence=0.95; method='wilson' }
}

function Get-ExactMcNemarP([int]$Wins,[int]$Losses) {
  $discordant = $Wins + $Losses
  if ($discordant -eq 0) { return [pscustomobject]@{ value=1.0; method='exact_binomial'; discordant=0 } }
  if ($discordant -gt 500) { return [pscustomobject]@{ value=$null; method='external_or_asymptotic_required'; discordant=$discordant } }
  $k = [Math]::Min($Wins,$Losses)
  $term = [Math]::Pow(0.5,$discordant)
  $tail = $term
  for ($i=1; $i -le $k; $i++) {
    $term *= ($discordant - $i + 1) / [double]$i
    $tail += $term
  }
  return [pscustomobject]@{ value=[Math]::Round([Math]::Min(1.0,2.0*$tail),8); method='exact_binomial'; discordant=$discordant }
}

function Write-Result($Value,[int]$ExitCode=0) {
  if ($Json) { $Value | ConvertTo-Json -Depth 16 }
  elseif ($Value.ok) { Write-Host "OBJECTIVE_BENCHMARK action=$Action status=$($Value.status)" }
  else { Write-Host "OBJECTIVE_BENCHMARK_FAILED code=$($Value.code)" }
  exit $ExitCode
}

try {
  $policy = Read-Json ([IO.Path]::GetFullPath($PolicyPath)) 'POLICY_INVALID'
  if ([string]$policy.schema -ne 'super-brain.objective-benchmark-policy.v1') { throw 'POLICY_SCHEMA_INVALID|unsupported policy schema' }

  if ($Action -eq 'Plan') {
    Write-Result ([pscustomobject]@{
      ok=$true
      action='Plan'
      schema='super-brain.objective-benchmark-plan.v1'
      status='not_scored'
      aggregateIntelligenceScore=$null
      aggregateScoreProhibited=$true
      design='paired_ab_same_host_model'
      singleChangedVariable='super_memory_brain_enabled'
      benchmarks=@($policy.benchmarks | ForEach-Object { [pscustomobject]@{ id=$_.id; name=$_.name; status='not_run'; officialRepo=$_.officialRepo; pinnedCommit=$_.pinnedCommit; officialMetric=$_.officialMetric; scope=$_.scope } })
      guard=[string]$policy.guard
    }) 0
  }

  $run = Read-Json ([IO.Path]::GetFullPath($ResultsPath)) 'RESULTS_INVALID'
  if ([string]$run.schema -ne 'super-brain.objective-benchmark-run.v1') { throw 'RESULTS_SCHEMA_INVALID|unsupported result schema' }
  foreach ($forbidden in @('score','aggregateScore','weightedScore','intelligenceScore')) {
    if ($null -ne $run.PSObject.Properties[$forbidden]) { throw 'CUSTOM_SCORE_FORBIDDEN|normalized external results cannot contain a custom score' }
  }
  $benchmark = @($policy.benchmarks | Where-Object { [string]$_.id -eq [string]$run.benchmarkId })
  if ($benchmark.Count -ne 1) { throw 'BENCHMARK_UNKNOWN|benchmark id is not registered' }
  $benchmark = $benchmark[0]
  if ([string]$run.officialSource.repo -ne [string]$benchmark.officialRepo -or [string]$run.officialSource.harnessCommit -ne [string]$benchmark.pinnedCommit) { throw 'OFFICIAL_SOURCE_MISMATCH|official repository or pinned harness commit does not match policy' }
  $artifactPath = [IO.Path]::GetFullPath([string]$run.officialSource.artifactPath)
  if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw 'OFFICIAL_ARTIFACT_MISSING|official harness artifact is missing' }
  $artifactHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($artifactHash -ne ([string]$run.officialSource.artifactSha256).ToLowerInvariant()) { throw 'OFFICIAL_ARTIFACT_HASH_MISMATCH|official harness artifact hash mismatch' }

  foreach ($requirement in @($policy.protocolRequirements)) {
    $property = $run.protocol.PSObject.Properties[[string]$requirement]
    if ($null -eq $property -or $property.Value -ne $true) { throw "PROTOCOL_NOT_COMPARABLE|required protocol flag is not true: $requirement" }
  }
  if ([string]$run.protocol.singleChangedVariable -ne [string]$policy.claimPolicy.singleChangedVariable) { throw 'PROTOCOL_NOT_COMPARABLE|Super Brain enablement must be the only changed variable' }
  if ([string]$run.protocol.baselineModelId -ne [string]$run.protocol.treatmentModelId -or [string]$run.protocol.baselineModelVersion -ne [string]$run.protocol.treatmentModelVersion) { throw 'MODEL_MISMATCH|baseline and treatment model identity must match' }

  $cases = @($run.cases)
  if ($cases.Count -lt 1) { throw 'RESULTS_EMPTY|at least one paired case is required' }
  $ids = @{}
  $baselinePassed = 0
  $treatmentPassed = 0
  $wins = 0
  $losses = 0
  foreach ($case in $cases) {
    $id = [string]$case.id
    if ([string]::IsNullOrWhiteSpace($id) -or $ids.ContainsKey($id)) { throw 'CASE_ID_INVALID|case ids must be non-empty and unique' }
    $ids[$id] = $true
    if ($case.baselinePassed -isnot [bool] -or $case.treatmentPassed -isnot [bool]) { throw 'CASE_RESULT_INVALID|paired outcomes must be Boolean' }
    if ($case.baselinePassed) { $baselinePassed++ }
    if ($case.treatmentPassed) { $treatmentPassed++ }
    if (-not $case.baselinePassed -and $case.treatmentPassed) { $wins++ }
    if ($case.baselinePassed -and -not $case.treatmentPassed) { $losses++ }
  }
  $baselineRate = $baselinePassed / [double]$cases.Count
  $treatmentRate = $treatmentPassed / [double]$cases.Count
  $fullSplit = ($run.protocol.fullOfficialSplit -eq $true)
  $minimumCaseAndSplitMet = ($cases.Count -ge [int]$benchmark.minimumPublishableCases -and ((-not [bool]$benchmark.fullOfficialSplitRequired) -or $fullSplit))
  # v1 was a self-attested normalization format. It cannot prove independent generation or judge isolation.
  $publishable = $false
  $report = [pscustomobject]@{
    ok=$true
    action='Evaluate'
    schema='super-brain.objective-benchmark-report.v1'
    status=if($publishable){'publishable_external_result'}else{'diagnostic_external_result'}
    benchmark=[pscustomobject]@{ id=$benchmark.id; name=$benchmark.name; officialMetric=$benchmark.officialMetric; scope=$benchmark.scope; officialRepo=$benchmark.officialRepo; harnessCommit=$benchmark.pinnedCommit }
    comparability=[pscustomobject]@{ paired=$true; cases=$cases.Count; fullOfficialSplit=$fullSplit; minimumPublishableCases=[int]$benchmark.minimumPublishableCases; minimumCaseAndSplitMet=$minimumCaseAndSplitMet; soleChangedVariable=[string]$run.protocol.singleChangedVariable; blindedJudging=$true; sameModel=$true; sameTools=$true; sameBudget=$true; sameEnvironment=$true; provenanceVerified=$false; legacySchemaDiagnosticOnly=$true }
    rawMetrics=[pscustomobject]@{
      baselinePassed=$baselinePassed
      treatmentPassed=$treatmentPassed
      total=$cases.Count
      baselinePassRate=[Math]::Round($baselineRate,6)
      treatmentPassRate=[Math]::Round($treatmentRate,6)
      pairedDeltaPercentagePoints=[Math]::Round(($treatmentRate-$baselineRate)*100.0,4)
      treatmentWins=$wins
      treatmentLosses=$losses
      ties=$cases.Count-$wins-$losses
      baseline95CI=Get-WilsonInterval $baselinePassed $cases.Count
      treatment95CI=Get-WilsonInterval $treatmentPassed $cases.Count
      pairedSignificance=Get-ExactMcNemarP $wins $losses
    }
    officialArtifact=[pscustomobject]@{ path=$artifactPath; sha256=$artifactHash }
    aggregateIntelligenceScore=$null
    aggregateScoreProhibited=$true
    publicationGuard='Legacy v1 result artifacts are diagnostic only because their protocol controls are self-attested. A future provenance-verified runner artifact is required before publication.'
    attribution='The full result belongs to the host model/tool/environment system; only the paired delta is attributable to Super Brain under this controlled protocol.'
  }
  if (-not [string]::IsNullOrWhiteSpace($ReportPath)) { Write-JsonUtf8NoBom ([IO.Path]::GetFullPath($ReportPath)) $report 20 }
  Write-Result $report 0
} catch {
  $parts = $_.Exception.Message -split '\|',2
  $code = if($parts.Count-eq2){$parts[0]}else{'OBJECTIVE_BENCHMARK_ERROR'}
  $message = if($parts.Count-eq2){$parts[1]}else{$_.Exception.Message}
  Write-Result ([pscustomobject]@{ok=$false;action=$Action;schema='super-brain.objective-benchmark-error.v1';code=$code;error=$message;aggregateIntelligenceScore=$null}) 1
}
