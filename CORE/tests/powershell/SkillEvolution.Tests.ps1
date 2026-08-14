$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$evolutionScript = Join-Path $root 'scripts\skill-evolution.ps1'
$bridgeScript = Join-Path $root 'scripts\evaluation-learning-bridge.ps1'

function Write-EvolutionTestJson([string]$Path, $Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
}

function Invoke-EvolutionTest([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $evolutionScript @Arguments 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; text=$text; value=$(if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}) }
}

function Invoke-BridgeTest([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bridgeScript @Arguments 2>&1)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; text=$text; value=$(if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}) }
}

function New-CurrentPhase6Binding {
  $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  return [pscustomobject]@{
    schema='super-brain.memory-e2e-binding.v1'
    packageVersion=[string]$manifest.version
    manifestSha256=(Get-FileHash -LiteralPath (Join-Path $root 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    brainCoreSha256=(Get-FileHash -LiteralPath (Join-Path $root 'runtime\brain_core.py') -Algorithm SHA256).Hash.ToLowerInvariant()
    phase6RuntimeSha256=(Get-FileHash -LiteralPath (Join-Path $root 'runtime\phase6_memory_eval.py') -Algorithm SHA256).Hash.ToLowerInvariant()
    writeMemorySha256=(Get-FileHash -LiteralPath (Join-Path $root 'scripts\write-memory.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    memoryPolicySha256=(Get-FileHash -LiteralPath (Join-Path $root 'memory-policy.json') -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function New-Phase6Aggregate($Binding,[bool]$Pass) {
  return [pscustomobject]@{
    schema='super-brain.memory-e2e-aggregate.v1'
    status='internal_acceptance_only'
    reportCount=2
    holdoutSetHashes=@((('a' * 64) -join ''),(('b' * 64) -join ''))
    familySetHashes=@((('c' * 64) -join ''),(('d' * 64) -join ''))
    evidenceBinding=$Binding
    bindingHash='test-binding-hash'
    fresh=$true
    twoFreshSealedE2EAtLeast90=$Pass
    unmetGateIds=$(if($Pass){@()}else{@('recall_at_10_at_least_95')})
    rawCasePayloadStored=$false
    objectiveIntelligenceScore=$false
  }
}

Describe 'Skill evolution evidence gates' {
  It 'keeps List read-only and stages a proposal without adopting it' {
    $workspace = Join-Path $TestDrive 'evolution'
    $list = Invoke-EvolutionTest @('-Mode','List','-WorkspaceRoot',$workspace,'-Json')
    $list.exitCode | Should Be 0
    Test-Path -LiteralPath $workspace | Should Be $false

    $proposal = Invoke-EvolutionTest @('-Mode','Propose','-WorkspaceRoot',$workspace,'-ProposalId','proposal-evidence-001','-Title','Bounded replay proposal','-Affected','runtime/test','-Proposal','Add one replay case after verified evaluation evidence.','-Evidence','aggregateHash=abc','-EvidenceFingerprint','fingerprint-001','-Json')
    $proposal.exitCode | Should Be 0
    $proposal.value.status | Should Be 'staged'
    $storedPath = Join-Path $workspace 'skill-evolution\proposals\proposal-evidence-001.json'
    $stored = Get-Content -LiteralPath $storedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $stored.status | Should Be 'staged'
    ([string]$stored.adoption).Contains('Requires user approval') | Should Be $true
    $stored.effect.status | Should Be 'not_scored'
    $stored.lifecycle.authority | Should Be 'self-improvement-queue.ps1'
    $stored.lifecycle.canonicalStage | Should Be 'candidate'
    $proposal.value.canonicalStage | Should Be 'candidate'

    $reused = Invoke-EvolutionTest @('-Mode','Propose','-WorkspaceRoot',$workspace,'-ProposalId','proposal-evidence-001','-Title','Bounded replay proposal','-Affected','runtime/test','-Proposal','Add one replay case after verified evaluation evidence.','-Evidence','aggregateHash=abc','-EvidenceFingerprint','fingerprint-001','-Json')
    $reused.exitCode | Should Be 0
    $reused.value.reused | Should Be $true
  }

  It 'treats v1 validation as historical and refuses to make it current adoption evidence' {
    $workspace = Join-Path $TestDrive 'validation'
    $proposal = Invoke-EvolutionTest @('-Mode','Propose','-WorkspaceRoot',$workspace,'-ProposalId','proposal-validate-001','-Title','Validation gate proposal','-Affected','runtime/test','-Proposal','Require a replay artifact before validation.','-Evidence','aggregateHash=def','-EvidenceFingerprint','fingerprint-validate-001','-Json')
    $proposal.exitCode | Should Be 0

    $withoutArtifact = Invoke-EvolutionTest @('-Mode','Validate','-WorkspaceRoot',$workspace,'-ProposalId','proposal-validate-001','-Pass','-Evidence','free text is insufficient','-Json')
    $withoutArtifact.exitCode | Should Not Be 0

    $artifactPath = Join-Path $workspace 'validation-artifact.json'
    Write-EvolutionTestJson $artifactPath ([pscustomobject]@{
      schema='super-brain.skill-evolution-validation.v1'
      proposalId='proposal-validate-001'
      evidenceFingerprint='fingerprint-validate-001'
      rawPromptStored=$false
      checks=[pscustomobject]@{ failureFixed=$true;criticalBehaviorPreserved=$true;noExtraVerbosity=$true;noPrivacyRegression=$true;noBroadAutoMutation=$true }
    })
    $validated = Invoke-EvolutionTest @('-Mode','Validate','-WorkspaceRoot',$workspace,'-ProposalId','proposal-validate-001','-Pass','-ValidationArtifactPath',$artifactPath,'-Json')
    $validated.exitCode | Should Be 0
    $validated.value.status | Should Be 'blocked'
    $validated.value.canonicalStage | Should Be 'historical'
    $stored = Get-Content -LiteralPath (Join-Path $workspace 'skill-evolution\proposals\proposal-validate-001.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $stored.validationArtifact.rawPromptStored | Should Be $false
    $stored.status | Should Be 'blocked'
    $stored.validation.contractVersion | Should Be 'legacy_v1'
    $stored.validation.status | Should Be 'historical'
    $stored.lifecycle.canonicalStage | Should Be 'historical'
  }

  It 'requires sealed replay and independent holdout evidence for current validation' {
    $workspace = Join-Path $TestDrive 'sealed-validation'
    $proposal = Invoke-EvolutionTest @('-Mode','Propose','-WorkspaceRoot',$workspace,'-ProposalId','proposal-sealed-001','-Title','Sealed validation proposal','-Affected','runtime/test','-Proposal','Require independent holdout validation before adoption.','-Evidence','aggregateHash=sealed','-EvidenceFingerprint','fingerprint-sealed-001','-Json')
    $proposal.exitCode | Should Be 0

    $invalidArtifact = Join-Path $workspace 'invalid-v2.json'
    Write-EvolutionTestJson $invalidArtifact ([pscustomobject]@{
      schema='super-brain.skill-evolution-validation.v2';proposalId='proposal-sealed-001';evidenceFingerprint='fingerprint-sealed-001';rawPromptStored=$false
      checks=[pscustomobject]@{ failureFixed=$true;criticalBehaviorPreserved=$true;noExtraVerbosity=$true;noPrivacyRegression=$true;noBroadAutoMutation=$true;sealedReplay=$true;sealedHoldout=$true;noConsumedHoldoutReuse=$true;overfitGuardPassed=$true }
      sealedEvaluation=[pscustomobject]@{ replayArtifactSha256=(('a' * 64) -join '');holdoutSetHash=(('b' * 64) -join '');holdoutUnused=$false;independentGeneration=$true }
    })
    (Invoke-EvolutionTest @('-Mode','Validate','-WorkspaceRoot',$workspace,'-ProposalId','proposal-sealed-001','-Pass','-ValidationArtifactPath',$invalidArtifact,'-Json')).exitCode | Should Not Be 0

    $validArtifact = Join-Path $workspace 'valid-v2.json'
    Write-EvolutionTestJson $validArtifact ([pscustomobject]@{
      schema='super-brain.skill-evolution-validation.v2';proposalId='proposal-sealed-001';evidenceFingerprint='fingerprint-sealed-001';rawPromptStored=$false
      checks=[pscustomobject]@{ failureFixed=$true;criticalBehaviorPreserved=$true;noExtraVerbosity=$true;noPrivacyRegression=$true;noBroadAutoMutation=$true;sealedReplay=$true;sealedHoldout=$true;noConsumedHoldoutReuse=$true;overfitGuardPassed=$true }
      sealedEvaluation=[pscustomobject]@{ replayArtifactSha256=(('a' * 64) -join '');holdoutSetHash=(('b' * 64) -join '');holdoutUnused=$true;independentGeneration=$true }
    })
    $validated = Invoke-EvolutionTest @('-Mode','Validate','-WorkspaceRoot',$workspace,'-ProposalId','proposal-sealed-001','-Pass','-ValidationArtifactPath',$validArtifact,'-Json')
    $validated.exitCode | Should Be 0
    $stored = Get-Content -LiteralPath (Join-Path $workspace 'skill-evolution\proposals\proposal-sealed-001.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $stored.validation.contractVersion | Should Be 'v2'
    $stored.validation.status | Should Be 'sealed-validated'
    $stored.validation.sealedHoldout | Should Be $true
    $stored.validation.overfitGuardPassed | Should Be $true
    $stored.lifecycle.canonicalStage | Should Be 'sealed-validated'
  }

  It 'deduplicates an identical captured failure before it can inflate the learning queue' {
    $workspace = Join-Path $TestDrive 'capture-dedupe'
    $arguments = @('-Mode','Capture','-WorkspaceRoot',$workspace,'-Title','Repeated route drift','-Trigger','same trigger','-Expected','keep the route','-Actual','route drifted','-Evidence','artifact:route-drift','-Affected','runtime','-Source','test','-EvidenceFingerprint','capture-dedupe-001','-Json')
    $first = Invoke-EvolutionTest $arguments
    $second = Invoke-EvolutionTest $arguments

    $first.exitCode | Should Be 0
    $first.value.reused | Should Be $false
    $second.exitCode | Should Be 0
    $second.value.reused | Should Be $true
    $second.value.id | Should Be $first.value.id
    $second.value.fingerprint | Should Be $first.value.fingerprint
    @(Get-ChildItem -LiteralPath (Join-Path $workspace 'skill-evolution\failures') -Filter '*.json' -File).Count | Should Be 1
  }

  It 'records a failed replay as rejected instead of an ungoverned failed state' {
    $workspace = Join-Path $TestDrive 'rejected-validation'
    $proposal = Invoke-EvolutionTest @('-Mode','Propose','-WorkspaceRoot',$workspace,'-ProposalId','proposal-reject-001','-Title','Rejectable proposal','-Affected','runtime/test','-Proposal','Reject when replay evidence does not pass.','-Evidence','aggregateHash=ghi','-EvidenceFingerprint','fingerprint-reject-001','-Json')
    $proposal.exitCode | Should Be 0

    $rejected = Invoke-EvolutionTest @('-Mode','Validate','-WorkspaceRoot',$workspace,'-ProposalId','proposal-reject-001','-Evidence','replay artifact did not pass','-Json')
    $rejected.exitCode | Should Be 0
    $rejected.value.status | Should Be 'rejected'
    (Get-Content -LiteralPath (Join-Path $workspace 'skill-evolution\proposals\proposal-reject-001.json') -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should Be 'rejected'
  }

  It 'stages only failing fresh Phase 6 evidence and leaves healthy evidence alone' {
    $binding = New-CurrentPhase6Binding
    $previewWorkspace = Join-Path $TestDrive 'bridge-preview'
    $stageWorkspace = Join-Path $TestDrive 'bridge-stage'
    $failingPath = Join-Path $TestDrive 'phase6-failing.json'
    $healthyPath = Join-Path $TestDrive 'phase6-healthy.json'
    Write-EvolutionTestJson $failingPath (New-Phase6Aggregate $binding $false)
    Write-EvolutionTestJson $healthyPath (New-Phase6Aggregate $binding $true)

    $preview = Invoke-BridgeTest @('-Action','Preview','-AggregatePath',$failingPath,'-WorkspaceRoot',$previewWorkspace,'-Json')
    $preview.exitCode | Should Be 0
    $preview.value.disposition | Should Be 'preview_only'
    Test-Path -LiteralPath $previewWorkspace | Should Be $false

    $staged = Invoke-BridgeTest @('-Action','Stage','-AggregatePath',$failingPath,'-WorkspaceRoot',$stageWorkspace,'-Json')
    $staged.exitCode | Should Be 0
    $staged.value.disposition | Should Be 'staged_only'
    $proposalFiles = @(Get-ChildItem -LiteralPath (Join-Path $stageWorkspace 'skill-evolution\proposals') -Filter '*.json' -File)
    $proposalFiles.Count | Should Be 1
    (Get-Content -LiteralPath $proposalFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should Be 'staged'

    $healthy = Invoke-BridgeTest @('-Action','Preview','-AggregatePath',$healthyPath,'-WorkspaceRoot',(Join-Path $TestDrive 'bridge-healthy'),'-Json')
    if ($healthy.exitCode -ne 0) { throw "healthy bridge failed: $($healthy.text)" }
    $healthy.exitCode | Should Be 0
    $healthy.value.disposition | Should Be 'healthy_no_proposal'
  }
}
