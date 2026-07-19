$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$intentRouter = Join-Path $root 'scripts\intent-router.ps1'
$whyPlan = Join-Path $root 'scripts\why-plan.ps1'
$preflight = Join-Path $root 'scripts\cognitive-preflight.ps1'
$policyPath = Join-Path $root 'memory-policy.json'

function Invoke-JsonScript([string]$Path, [string[]]$Arguments) {
  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>$null
  if($LASTEXITCODE -ne 0){ throw "Script failed: $Path exit=$LASTEXITCODE" }
  return (($raw -join "`n") | ConvertFrom-Json)
}

Describe 'Collaborative intent gate' {
  It 'routes feature work through product coherence and bounded autonomy' {
    $result = Invoke-JsonScript $intentRouter @('-Text','add a feature to the product','-Json')
    $result.intent | Should Be 'add_or_optimize_feature'
    (@($result.dispatchHints) -contains 'collaborative_intent') | Should Be $true
    (@($result.dispatchHints) -contains 'product_coherence_gate') | Should Be $true
    (@($result.commands) -contains 'references\collaborative-intent.md') | Should Be $true
  }

  It 'builds an align contract for workflow changes' {
    $result = Invoke-JsonScript $whyPlan @('-Goal','add a feature to the product workflow','-Json')
    $result.collaborationGate.changeClass | Should Be 'workflow'
    $result.collaborationGate.autonomyTier | Should Be 'align'
    $result.collaborationGate.alignmentRequired | Should Be $true
    $result.collaborationGate.verificationBudget | Should Be 'core_path_and_targeted_regression'
    $result.collaborationGate.memoryBoundary.sharedExperience | Should Match 'two verified'
  }

  It 'requires discussion for structural feature impact' {
    $result = Invoke-JsonScript $whyPlan @('-Goal','add a feature that changes the data model and API','-Json')
    $result.collaborationGate.changeClass | Should Be 'structural'
    $result.collaborationGate.autonomyTier | Should Be 'discuss'
    $result.collaborationGate.verificationBudget | Should Be 'integration_and_rollback'
    $result.collaborationGate.decisionIfAmbiguous | Should Match 'Discuss'
  }

  It 'keeps a small local task on the direct path' {
    $result = Invoke-JsonScript $whyPlan @('-Goal','fix a typo in a label','-Json')
    $result.collaborationGate.changeClass | Should Be 'local'
    $result.collaborationGate.autonomyTier | Should Be 'direct'
    $result.collaborationGate.applicable | Should Be $false
  }

  It 'adds product coherence cards to feature preflight' {
    $result = Invoke-JsonScript $preflight @('-Query','add a feature to the product workflow','-Scope','collaboration-test','-Json')
    @($result.cards | Where-Object { $_.kind -eq 'product_coherence' }).Count | Should BeGreaterThan 0
    (@($result.driftGuards) -contains 'feature_implemented_without_product_role') | Should Be $true
    @($result.procedureExpectations | Where-Object { $_.cardId -eq 'collaborative-intent' }).Count | Should Be 1
  }

  It 'keeps project context separate from promoted shared experience' {
    $policy = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $policy.collaboration.projectModel.scope | Should Be 'project'
    $policy.collaboration.projectModel.maxFacts | Should Be 24
    $policy.collaboration.sharedExperience.promoteAfterVerifiedUses | Should Be 2
    $policy.collaboration.sharedExperience.retrievalCards | Should Be 2
    $policy.collaboration.sharedExperience.maxEntries | Should Be 80
  }
}
