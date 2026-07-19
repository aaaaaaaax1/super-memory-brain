$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\objective-benchmark.ps1'
$policyPath = Join-Path $root 'objective-benchmark-policy.json'

function Write-ObjectiveJson([string]$Path,$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
}

function Invoke-Objective([string[]]$Arguments) {
  $raw=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>$null)
  return [pscustomobject]@{exitCode=$LASTEXITCODE;value=(($raw-join"`n")|ConvertFrom-Json)}
}

function New-ObjectiveRun([string]$ArtifactPath,[string]$ArtifactHash) {
  $policy=Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8|ConvertFrom-Json
  $benchmark=$policy.benchmarks|Where-Object id -eq 'swebench_verified'
  return [pscustomobject]@{
    schema='super-brain.objective-benchmark-run.v1'
    benchmarkId='swebench_verified'
    officialSource=[pscustomobject]@{repo=$benchmark.officialRepo;harnessCommit=$benchmark.pinnedCommit;artifactPath=$ArtifactPath;artifactSha256=$ArtifactHash}
    protocol=[pscustomobject]@{sameModel=$true;sameModelVersion=$true;sameTools=$true;sameBudget=$true;sameEnvironment=$true;randomizedOrder=$true;blindedJudging=$true;noTrainingOnEvaluationCases=$true;officialHarness=$true;singleChangedVariable='super_memory_brain_enabled';baselineModelId='same-model';treatmentModelId='same-model';baselineModelVersion='pinned';treatmentModelVersion='pinned';fullOfficialSplit=$false}
    cases=@(
      [pscustomobject]@{id='a';baselinePassed=$false;treatmentPassed=$true},
      [pscustomobject]@{id='b';baselinePassed=$true;treatmentPassed=$true},
      [pscustomobject]@{id='c';baselinePassed=$true;treatmentPassed=$false},
      [pscustomobject]@{id='d';baselinePassed=$false;treatmentPassed=$true}
    )
  }
}

Describe 'Objective benchmark contract' {
  It 'reports not_scored before official paired runs and exposes no aggregate score' {
    $result=Invoke-Objective @('-Action','Plan','-Json')
    $result.exitCode|Should Be 0
    $result.value.status|Should Be 'not_scored'
    $result.value.aggregateIntelligenceScore|Should Be $null
    $result.value.aggregateScoreProhibited|Should Be $true
    @($result.value.benchmarks|Where-Object status -ne 'not_run').Count|Should Be 0
  }

  It 'reports raw paired metrics without inventing a cross-benchmark score' {
    $artifact=Join-Path $TestDrive 'official-output.json'
    [IO.File]::WriteAllText($artifact,'{"official":true}',[Text.UTF8Encoding]::new($false))
    $hash=(Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $runPath=Join-Path $TestDrive 'run.json'
    Write-ObjectiveJson $runPath (New-ObjectiveRun $artifact $hash)
    $result=Invoke-Objective @('-Action','Evaluate','-ResultsPath',$runPath,'-Json')
    $result.exitCode|Should Be 0
    $result.value.status|Should Be 'diagnostic_external_result'
    $result.value.rawMetrics.baselinePassRate|Should Be 0.5
    $result.value.rawMetrics.treatmentPassRate|Should Be 0.75
    $result.value.rawMetrics.pairedDeltaPercentagePoints|Should Be 25
    $result.value.aggregateIntelligenceScore|Should Be $null
    $result.value.aggregateScoreProhibited|Should Be $true
  }

  It 'rejects unblinded or model-mismatched comparisons' {
    $artifact=Join-Path $TestDrive 'official-output-guard.json'
    [IO.File]::WriteAllText($artifact,'{}',[Text.UTF8Encoding]::new($false))
    $hash=(Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $run=New-ObjectiveRun $artifact $hash
    $run.protocol.blindedJudging=$false
    $runPath=Join-Path $TestDrive 'unblinded.json'
    Write-ObjectiveJson $runPath $run
    $result=Invoke-Objective @('-Action','Evaluate','-ResultsPath',$runPath,'-Json')
    $result.exitCode|Should Be 1
    $result.value.code|Should Be 'PROTOCOL_NOT_COMPARABLE'

    $run.protocol.blindedJudging=$true
    $run.protocol.treatmentModelVersion='different'
    Write-ObjectiveJson $runPath $run
    $result=Invoke-Objective @('-Action','Evaluate','-ResultsPath',$runPath,'-Json')
    $result.exitCode|Should Be 1
    $result.value.code|Should Be 'MODEL_MISMATCH'
  }

  It 'keeps legacy v1 artifacts diagnostic even when their self-attested threshold is met' {
    $artifact=Join-Path $TestDrive 'official-output-v1-full.json'
    [IO.File]::WriteAllText($artifact,'{}',[Text.UTF8Encoding]::new($false))
    $hash=(Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $run=New-ObjectiveRun $artifact $hash
    $run.protocol.fullOfficialSplit=$true
    $run.cases=@(1..50|ForEach-Object { [pscustomobject]@{id="case-$_";baselinePassed=$true;treatmentPassed=$true} })
    $runPath=Join-Path $TestDrive 'legacy-v1-full.json'
    Write-ObjectiveJson $runPath $run
    $result=Invoke-Objective @('-Action','Evaluate','-ResultsPath',$runPath,'-Json')
    $result.exitCode|Should Be 0
    $result.value.status|Should Be 'diagnostic_external_result'
    $result.value.comparability.minimumCaseAndSplitMet|Should Be $true
    $result.value.comparability.provenanceVerified|Should Be $false
    $result.value.comparability.legacySchemaDiagnosticOnly|Should Be $true
  }
}
