$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$evalScript = Join-Path $root 'scripts\intelligence-eval.ps1'

function Write-TestJson([string]$Path, $Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
}

function Invoke-IntelligenceEval([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $evalScript @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode=$exitCode; text=$text; value=$value }
}

function Get-CurrentEvidenceBinding {
  $result = Invoke-IntelligenceEval @('-Action','Binding','-Json')
  $result.exitCode | Should Be 0
  return $result.value.binding
}

function New-HoldoutSource([int]$Count, [string]$PromptMarker) {
  $cases = @()
  for ($i=0; $i -lt $Count; $i++) {
    $cases += [pscustomobject]@{ id=('case-{0:d3}' -f $i); prompt="$PromptMarker variant $i"; expected=[pscustomobject]@{ route='bounded'; refuseUnknown=$true }; tags=@('unseen','paraphrase') }
  }
  return [pscustomobject]@{ schema='super-brain.intelligence-holdout-source.v1'; setId=('holdout-'+[guid]::NewGuid().ToString('n')); cases=$cases }
}

function Seal-Holdout([string]$Directory, [int]$Count, [string]$PromptMarker) {
  $sourcePath = Join-Path $Directory 'source.json'
  $sealedPath = Join-Path $Directory 'sealed.json'
  Write-TestJson $sourcePath (New-HoldoutSource $Count $PromptMarker)
  $seal = Invoke-IntelligenceEval @('-Action','Seal','-HoldoutPath',$sourcePath,'-OutputPath',$sealedPath,'-Json')
  $seal.exitCode | Should Be 0
  return [pscustomobject]@{ path=$sealedPath; value=(Get-Content -LiteralPath $sealedPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
}

function New-Dimensions([double]$Rate = 0.96, [string]$MissingEvidence = '') {
  $dimensions = [ordered]@{}
  foreach ($name in @('reliability','memoryGovernance','generalization','continuity','toolRouting','correctionLearning','maintainability','efficiency')) {
    $refs = if ($name -eq $MissingEvidence) { @() } else { @("metric-$name") }
    $dimensions[$name] = [pscustomobject]@{ rate=$Rate; sampleCount=20; evidenceRefs=$refs }
  }
  return [pscustomobject]$dimensions
}

function New-Evidence($Sealed, [int]$HoldoutPassed, [int]$CalibrationPassed, [string]$MissingDimensionEvidence = '', [switch]$LowAutonomy) {
  $calibration = @()
  for ($i=0; $i -lt 50; $i++) { $calibration += [pscustomobject]@{ id="cal-$i"; passed=($i -lt $CalibrationPassed); evidenceRefs=@("cal-artifact-$i") } }
  $holdoutResults = @()
  $index = 0
  foreach ($case in @($Sealed.cases)) {
    $holdoutResults += [pscustomobject]@{ id=[string]$case.id; caseHash=[string]$case.caseHash; passed=($index -lt $HoldoutPassed); evidenceRefs=@("holdout-artifact-$index") }
    $index++
  }
  $counts = if ($LowAutonomy) { [pscustomobject]@{ verifiedRealWorldTasks=0; verifiedAutonomyScenarios=0; closedCorrectionLoops=0 } } else { [pscustomobject]@{ verifiedRealWorldTasks=20; verifiedAutonomyScenarios=30; closedCorrectionLoops=5 } }
  return [pscustomobject]@{ schema='super-brain.intelligence-evidence.v1'; generatedAt=(Get-Date).ToUniversalTime().ToString('o'); evidenceBinding=(Get-CurrentEvidenceBinding); dimensions=(New-Dimensions 0.96 $MissingDimensionEvidence); calibrationCases=$calibration; holdoutResults=$holdoutResults; evidenceCounts=$counts }
}

function New-BoundEvidence($Dimensions, $CalibrationCases, $Counts) {
  return [pscustomobject]@{ schema='super-brain.intelligence-evidence.v1'; generatedAt=(Get-Date).ToUniversalTime().ToString('o'); evidenceBinding=(Get-CurrentEvidenceBinding); dimensions=$Dimensions; calibrationCases=$CalibrationCases; evidenceCounts=$Counts }
}

Describe 'IntelligenceEval' {
  It 'rejects a scoring policy whose target weights do not sum to one' {
    $dir = Join-Path $TestDrive 'invalid-weights'
    $policy = Get-Content -LiteralPath (Join-Path $root 'intelligence-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $policy.weights.autonomousBrain.reliability = 0.5
    $policyPath = Join-Path $dir 'policy.json'
    Write-TestJson $policyPath $policy
    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-PolicyPath',$policyPath,'-EvidencePath',(Join-Path $dir 'missing.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'POLICY_WEIGHT_SUM_INVALID'
  }

  It 'validates a sealed holdout and omits every raw prompt from the report' {
    $dir = Join-Path $TestDrive 'valid'
    $marker = 'NEVER_COPY_RAW_HOLDOUT_PROMPT_731'
    $sealed = Seal-Holdout $dir 50 $marker
    $evidencePath = Join-Path $dir 'evidence.json'
    $reportPath = Join-Path $dir 'report.json'
    $consumedPath = Join-Path $dir 'consumed.json'
    Write-TestJson $evidencePath (New-Evidence $sealed.value 46 48)

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-HoldoutPath',$sealed.path,'-EvidencePath',$evidencePath,'-ReportPath',$reportPath,'-ConsumedMarkerPath',$consumedPath,'-Json')
    $result.exitCode | Should Be 0
    $result.value.holdout.verified | Should Be $true
    $result.value.holdout.caseCount | Should Be 50
    $result.value.antiOverfitting.gap | Should Be 0.04
    $result.value.scores.personalControlPlane.achieved | Should Be $true
    Test-Path -LiteralPath $consumedPath | Should Be $true
    $consumed = Get-Content -LiteralPath $consumedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $consumed.reportHash | Should Be (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $result.text.Contains($marker) | Should Be $false
    (Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8).Contains($marker) | Should Be $false
    $result.value.privacy.rawHoldoutPromptsCopiedToReport | Should Be $false
    $result.value.evaluationScope | Should Be 'internal_acceptance_only'
    $result.value.objectiveIntelligenceScore | Should Be $false
    $result.value.externalBenchmarkRequiredForObjectiveClaim | Should Be $true
  }

  It 'rejects a holdout whose sealed case payload was modified' {
    $dir = Join-Path $TestDrive 'tampered'
    $marker = 'TAMPER_SENTINEL_RAW_PROMPT'
    $sealed = Seal-Holdout $dir 3 $marker
    $sealed.value.cases[0].payload.prompt = 'changed after sealing'
    Write-TestJson $sealed.path $sealed.value
    $evidencePath = Join-Path $dir 'evidence.json'
    Write-TestJson $evidencePath (New-Evidence $sealed.value 3 50)

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-HoldoutPath',$sealed.path,'-EvidencePath',$evidencePath,'-ReportPath',(Join-Path $dir 'report.json'),'-ConsumedMarkerPath',(Join-Path $dir 'consumed.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'HOLDOUT_CASE_HASH_MISMATCH'
    $result.text.Contains($marker) | Should Be $false
  }

  It 'subtracts the calibration-to-holdout overfit gap from both scores' {
    $dir = Join-Path $TestDrive 'overfit'
    $sealed = Seal-Holdout $dir 50 'OVERFIT_CASE'
    $evidence = New-Evidence $sealed.value 40 50
    foreach ($property in $evidence.dimensions.PSObject.Properties) { $property.Value.rate = 1.0 }
    $evidencePath = Join-Path $dir 'evidence.json'
    Write-TestJson $evidencePath $evidence

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-HoldoutPath',$sealed.path,'-EvidencePath',$evidencePath,'-ReportPath',(Join-Path $dir 'report.json'),'-ConsumedMarkerPath',(Join-Path $dir 'consumed.json'),'-Json')
    $result.exitCode | Should Be 0
    $result.value.antiOverfitting.gap | Should Be 0.2
    $result.value.antiOverfitting.penalty | Should Be 2
    ([double]$result.value.scores.personalControlPlane.raw - [double]$result.value.scores.personalControlPlane.final) | Should Be 2
    @($result.value.scores.personalControlPlane.unmetGates) -contains 'personal_overfit_gap' | Should Be $true
  }

  It 'enforces no-holdout score ceilings even with perfect supplied dimensions' {
    $dir = Join-Path $TestDrive 'no-holdout'
    $calibration = @()
    for ($i=0; $i -lt 10; $i++) { $calibration += [pscustomobject]@{ id="cal-$i"; passed=$true; evidenceRefs=@("cal-$i") } }
    $evidence = New-BoundEvidence (New-Dimensions 1.0) $calibration ([pscustomobject]@{ verifiedRealWorldTasks=20; verifiedAutonomyScenarios=30; closedCorrectionLoops=5 })
    $evidencePath = Join-Path $dir 'evidence.json'
    Write-TestJson $evidencePath $evidence

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-EvidencePath',$evidencePath,'-ReportPath',(Join-Path $dir 'report.json'),'-Json')
    $result.exitCode | Should Be 0
    $result.value.scores.personalControlPlane.final | Should Be 8
    $result.value.scores.autonomousBrain.final | Should Be 6.5
    @($result.value.scores.personalControlPlane.ceilingReasons) -contains 'no_sealed_holdout' | Should Be $true
  }

  It 'derives autonomy counts from the ledger and ignores caller supplied counts' {
    $dir = Join-Path $TestDrive 'ledger-derived-counts'
    $workspace = Join-Path $dir 'workspace'
    $workspaceKey = 'ws-111111111111111111111111'
    $calibration = @()
    for ($i=0; $i -lt 10; $i++) { $calibration += [pscustomobject]@{ id="cal-$i"; passed=$true; evidenceRefs=@("cal-$i") } }
    $evidence = New-BoundEvidence (New-Dimensions 1.0) $calibration ([pscustomobject]@{ verifiedRealWorldTasks=20; verifiedAutonomyScenarios=30; closedCorrectionLoops=5 })
    $evidencePath = Join-Path $dir 'evidence.json'
    Write-TestJson $evidencePath $evidence

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-EvidencePath',$evidencePath,'-ReportPath',(Join-Path $dir 'report.json'),'-AutonomyWorkspaceRoot',$workspace,'-WorkspaceKey',$workspaceKey,'-Json')
    $result.exitCode | Should Be 0
    $result.value.evidenceCounts.verifiedRealWorldTasks | Should Be 0
    $result.value.evidenceCounts.verifiedAutonomyScenarios | Should Be 0
    $result.value.evidenceCounts.closedCorrectionLoops | Should Be 0
    $result.value.autonomyEvidence.callerSuppliedCountsIgnored | Should Be $true
    $result.value.autonomyEvidence.genericCompletionCounts | Should Be $false
  }

  It 'cannot claim a target when dimension evidence or autonomy evidence is missing' {
    $dir = Join-Path $TestDrive 'missing-evidence'
    $sealed = Seal-Holdout $dir 50 'MISSING_EVIDENCE_CASE'
    $evidence = New-Evidence $sealed.value 50 50 'memoryGovernance' -LowAutonomy
    foreach ($property in $evidence.dimensions.PSObject.Properties) { $property.Value.rate = 1.0 }
    $evidencePath = Join-Path $dir 'evidence.json'
    Write-TestJson $evidencePath $evidence

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-HoldoutPath',$sealed.path,'-EvidencePath',$evidencePath,'-ReportPath',(Join-Path $dir 'report.json'),'-ConsumedMarkerPath',(Join-Path $dir 'consumed.json'),'-Json')
    $result.exitCode | Should Be 0
    $result.value.scores.personalControlPlane.achieved | Should Be $false
    $result.value.scores.autonomousBrain.achieved | Should Be $false
    @($result.value.scores.personalControlPlane.unmetGates) -contains 'dimension_evidence_complete' | Should Be $true
    @($result.value.scores.autonomousBrain.unmetGates) -contains 'verified_real_world_tasks' | Should Be $true
    $result.value.scores.autonomousBrain.ceiling | Should Be 7.5
  }

  It 'rejects evidence without a current package binding' {
    $dir = Join-Path $TestDrive 'missing-binding'
    $calibration = @([pscustomobject]@{ id='cal-0'; passed=$true; evidenceRefs=@('cal-0') })
    $evidence = [pscustomobject]@{ schema='super-brain.intelligence-evidence.v1'; generatedAt=(Get-Date).ToUniversalTime().ToString('o'); dimensions=(New-Dimensions 1.0); calibrationCases=$calibration; evidenceCounts=[pscustomobject]@{ verifiedRealWorldTasks=0; verifiedAutonomyScenarios=0; closedCorrectionLoops=0 } }
    $evidencePath = Join-Path $dir 'evidence.json'
    Write-TestJson $evidencePath $evidence

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-EvidencePath',$evidencePath,'-ReportPath',(Join-Path $dir 'report.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'EVIDENCE_BINDING_MISSING'
  }

  It 'rejects stale evidence even when its binding is current' {
    $dir = Join-Path $TestDrive 'stale-evidence'
    $calibration = @([pscustomobject]@{ id='cal-0'; passed=$true; evidenceRefs=@('cal-0') })
    $evidence = New-BoundEvidence (New-Dimensions 1.0) $calibration ([pscustomobject]@{ verifiedRealWorldTasks=0; verifiedAutonomyScenarios=0; closedCorrectionLoops=0 })
    $evidence.generatedAt = (Get-Date).ToUniversalTime().AddHours(-100).ToString('o')
    $evidencePath = Join-Path $dir 'evidence.json'
    Write-TestJson $evidencePath $evidence

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-EvidencePath',$evidencePath,'-ReportPath',(Join-Path $dir 'report.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'EVIDENCE_STALE'
  }

  It 'rejects evidence bound to a different package version' {
    $dir = Join-Path $TestDrive 'version-drift'
    $calibration = @([pscustomobject]@{ id='cal-0'; passed=$true; evidenceRefs=@('cal-0') })
    $evidence = New-BoundEvidence (New-Dimensions 1.0) $calibration ([pscustomobject]@{ verifiedRealWorldTasks=0; verifiedAutonomyScenarios=0; closedCorrectionLoops=0 })
    $evidence.evidenceBinding = [pscustomobject]@{ schema=[string]$evidence.evidenceBinding.schema; packageVersion='0.0.0-test-drift'; manifestSha256=[string]$evidence.evidenceBinding.manifestSha256; runtimeSourceSha256=[string]$evidence.evidenceBinding.runtimeSourceSha256; runtimeFiles=@($evidence.evidenceBinding.runtimeFiles) }
    $evidencePath = Join-Path $dir 'evidence.json'
    Write-TestJson $evidencePath $evidence

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-EvidencePath',$evidencePath,'-ReportPath',(Join-Path $dir 'report.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'EVIDENCE_PACKAGE_VERSION_MISMATCH'
  }

  It 'rejects evidence whose behavior source binding drifted' {
    $dir = Join-Path $TestDrive 'behavior-drift'
    $calibration = @([pscustomobject]@{ id='cal-0'; passed=$true; evidenceRefs=@('cal-0') })
    $evidence = New-BoundEvidence (New-Dimensions 1.0) $calibration ([pscustomobject]@{ verifiedRealWorldTasks=0; verifiedAutonomyScenarios=0; closedCorrectionLoops=0 })
    $evidence.evidenceBinding | Add-Member -NotePropertyName behaviorSourceSha256 -NotePropertyValue '00' -Force
    $evidencePath = Join-Path $dir 'evidence.json'
    Write-TestJson $evidencePath $evidence

    $result = Invoke-IntelligenceEval @('-Action','Evaluate','-EvidencePath',$evidencePath,'-ReportPath',(Join-Path $dir 'report.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'EVIDENCE_BEHAVIOR_HASH_MISMATCH'
  }
}
