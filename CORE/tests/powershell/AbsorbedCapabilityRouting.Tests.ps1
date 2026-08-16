$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$RouteScript = Join-Path $Root 'scripts\absorbed-capability-route.ps1'
$IntentRouter = Join-Path $Root 'scripts\intent-router.ps1'
$HotRefresh = Join-Path $Root 'scripts\hot-refresh-skills.ps1'
$CapabilityMap = Join-Path $Root 'scripts\skill-capability-map.ps1'
. (Join-Path $Root 'scripts\common.ps1')

function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }

function Invoke-Route([string]$StateRoot,[string]$Text,[string]$Intent = '') {
  $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RouteScript -Text $Text -Intent $Intent -Json 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }
  $text = ($raw -join "`n")
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text | ConvertFrom-Json}else{$null}; text=$text }
}

function Invoke-IntentRoute([string]$StateRoot,[string]$Text) {
  $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $IntentRouter -Text $Text -Json 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }
  $text = ($raw -join "`n")
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text | ConvertFrom-Json}else{$null}; text=$text }
}

function Invoke-CapabilityMap([string]$StateRoot) {
  $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CapabilityMap -List -TopK 256 -Json 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }
  $text = ($raw -join "`n")
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text | ConvertFrom-Json}else{$null}; text=$text }
}

Describe 'Absorbed capability automatic routing' {
  It 'routes bug diagnosis to explicit Matt metadata with live provenance' {
    $stateRoot = Join-Path $TestDrive ('absorbed-route-bug-' + [guid]::NewGuid().ToString('n'))
    $result = Invoke-Route $stateRoot 'diagnose a performance regression and find the root cause' 'fix_bug'
    $bug = @($result.value.capabilities | Where-Object { $_.name -eq 'diagnosing-bugs' } | Select-Object -First 1)

    $result.exitCode | Should Be 0
    $result.value.state | Should Be 'ready'
    $result.value.selected | Should Be $true
    $bug.category | Should Be 'engineering'
    $bug.role | Should Be 'bug_diagnosis'
    (@($bug.semanticTags) -contains 'bug_diagnosis') | Should Be $true
    $bug.routingMetadataSource | Should Be 'manifest_explicit'
    $bug.executionOwner | Should Be 'super-memory-brain'
    $bug.standaloneInstall | Should Be $false
    $bug.sourceRepo | Should Be 'https://github.com/mattpocock/skills'
    $bug.sourceCommit | Should Be '6eeb81b5fcfeeb5bd531dd47ab2f9f2bbea27461'
    $bug.license | Should Be 'MIT'
    $bug.provenanceStatus | Should Be 'verified'
    $bug.sourceManifestHash | Should Match '^[a-f0-9]{64}$'
    $bug.skillSha256 | Should Match '^[a-f0-9]{64}$'
    $bug.provenanceHash | Should Match '^[a-f0-9]{64}$'
    $bug.upstreamInvocation | Should Be 'provenance_cold_reference_only'
    $bug.upstreamAuthoredInvocation | Should Be 'model_invocable_upstream'
    $bug.sourceUse | Should Be 'provenance_cold_reference_only'
    $bug.invocationMode | Should Be 'super_brain_native_contract'
    $bug.nativeBehaviorContractId | Should Be 'sb.native.engineering.evidence-loop.v1'
    $bug.nativeRouteReceipt.contractId | Should Be 'sb.native.engineering.evidence-loop.v1'
    $bug.nativeRouteReceipt.entry | Should Be 'evidence_first_engineering_loop'
  }

  It 'routes Grill Me as one Super Brain-owned cold challenge gate, not a host skill' {
    $stateRoot = Join-Path $TestDrive ('absorbed-route-grill-' + [guid]::NewGuid().ToString('n'))
    $result = Invoke-Route $stateRoot 'grill this plan and challenge the assumptions' 'add_or_optimize_feature'
    $grill = @($result.value.capabilities | Where-Object { $_.name -eq 'grill-me' } | Select-Object -First 1)

    $result.exitCode | Should Be 0
    $result.value.selected | Should Be $true
    (@($result.value.capabilities.name) -contains 'grill-me') | Should Be $true
    (@($result.value.capabilities.name) -contains 'grilling') | Should Be $false
    $grill.executionOwner | Should Be 'super-memory-brain'
    $grill.standaloneInstall | Should Be $false
    $grill.sourceKind | Should Be 'absorbed_package_capability_source'
    $grill.sourcePath | Should Match 'extensions[\\/]mattpocock-skills'
    $grill.upstreamInvocation | Should Be 'provenance_cold_reference_only'
    $grill.upstreamAuthoredInvocation | Should Be 'user_only_upstream'
    $grill.sourceUse | Should Be 'provenance_cold_reference_only'
    $grill.invocationMode | Should Be 'super_brain_internal_challenge_gate'
    $grill.adapterTarget | Should Be 'grilling'
    $grill.mutualExclusionGroup | Should Be 'challenge_interview'
    $grill.nativeBehaviorContractId | Should Be 'sb.native.challenge.gate.v1'
    $grill.nativeRouteReceipt.contractId | Should Be 'sb.native.challenge.gate.v1'
    $grill.nativeRouteReceipt.entry | Should Be 'bounded_challenge_gate'
    $grill.nativeRouteReceipt.parityProcedureId | Should Be 'sb.native.challenge.gate.v1'
    $expectedParityPayload = [ordered]@{
      capabilityId = [string]$grill.capabilityId
      contractId = [string]$grill.nativeBehaviorContract.id
      contractEntry = [string]$grill.nativeBehaviorContract.entry
      sourceUse = [string]$grill.nativeBehaviorContract.sourceUse
      parityMapping = $grill.nativeParityMapping
    }
    $grill.nativeRouteReceipt.parityHash | Should Be (Get-SuperBrainStableHash (($expectedParityPayload | ConvertTo-Json -Depth 10 -Compress)) 64)
  }

  It 'keeps the challenge gate primary when a stress-test phrase also matches generic testing, while true TDD still routes' {
    $stateRoot = Join-Path $TestDrive ('absorbed-route-challenge-priority-' + [guid]::NewGuid().ToString('n'))
    $mixed = Invoke-Route $stateRoot 'Grill this engineering plan: challenge assumptions and stress test it.' 'design_evaluate'
    $tdd = Invoke-Route $stateRoot 'Use TDD: test first with red green refactor for this bug.' 'fix_bug'
    $mixedGrill = @($mixed.value.capabilities | Where-Object { $_.name -eq 'grill-me' } | Select-Object -First 1)
    $tddCard = @($tdd.value.capabilities | Where-Object { $_.name -eq 'tdd' } | Select-Object -First 1)

    $mixed.exitCode | Should Be 0
    $mixed.value.state | Should Be 'ready'
    $mixed.value.selectionPolicy | Should Be 'challenge_semantic_priority'
    $mixed.value.capabilities[0].name | Should Be 'grill-me'
    $mixedGrill.routePriority | Should Be 100
    $mixedGrill.nativeRouteReceipt.contractId | Should Be 'sb.native.challenge.gate.v1'
    $tdd.exitCode | Should Be 0
    $tdd.value.state | Should Be 'ready'
    $tdd.value.capabilities[0].name | Should Be 'tdd'
    $tddCard.upstreamInvocation | Should Be 'provenance_cold_reference_only'
    $tddCard.nativeBehaviorContractId | Should Be 'sb.native.engineering.evidence-loop.v1'
  }

  It 'keeps productivity and teaching out of product planning while retaining product specification routing' {
    $stateRoot = Join-Path $TestDrive ('absorbed-route-productivity-' + [guid]::NewGuid().ToString('n'))
    $productivity = (U @(25552,36895,25928,29575,65292,20132,25509,24403,21069,24037,20316,32473,19979,19968,20010,20250))
    $handoff = Invoke-Route $stateRoot $productivity 'add_or_optimize_feature'
    $teach = Invoke-Route $stateRoot ((U @(25945,25105)) + ' how to design a reusable capability') 'general_task'
    $prd = Invoke-Route $stateRoot 'turn this into a PRD requirements specification' 'add_or_optimize_feature'

    (@($handoff.value.semanticSignals) -contains 'productivity_workflow') | Should Be $true
    (@($handoff.value.capabilities.name) -contains 'handoff') | Should Be $true
    @($handoff.value.capabilities.name | Where-Object { $_ -in @('to-prd','to-issues','triage','prototype') }).Count | Should Be 0
    (@($teach.value.capabilities.name) -contains 'teach') | Should Be $true
    @($teach.value.capabilities.name | Where-Object { $_ -in @('to-prd','to-issues','triage','prototype') }).Count | Should Be 0
    (@($prd.value.capabilities.name) -contains 'to-prd') | Should Be $true
    (@($prd.value.capabilities.name) -contains 'handoff') | Should Be $false
    $prdCard = @($prd.value.capabilities | Where-Object { $_.name -eq 'to-prd' } | Select-Object -First 1)
    $prdCard.externalActionPolicy | Should Be 'proposal_only_until_exact_user_approval'
    $prdCard.policySource | Should Be 'manifest_explicit'
    $handoffCard = @($handoff.value.capabilities | Where-Object { $_.name -eq 'handoff' } | Select-Object -First 1)
    $teachCard = @($teach.value.capabilities | Where-Object { $_.name -eq 'teach' } | Select-Object -First 1)
    $handoffCard.upstreamInvocation | Should Be 'provenance_cold_reference_only'
    $handoffCard.nativeBehaviorContractId | Should Be 'sb.native.h7.handoff.v1'
    $handoffCard.nativeRouteReceipt.entry | Should Be 'h7_continuity_handoff'
    $teachCard.nativeBehaviorContractId | Should Be 'sb.native.productivity.learning-loop.v1'
    $prdCard.nativeBehaviorContractId | Should Be 'sb.native.product-planning.proposal-loop.v1'
  }

  It 'keeps continuation and status paths H7-only instead of re-routing a cold capability' {
    $stateRoot = Join-Path $TestDrive ('absorbed-route-h7-only-' + [guid]::NewGuid().ToString('n'))
    $result = Invoke-Route $stateRoot 'continue' 'continue'

    $result.exitCode | Should Be 0
    $result.value.state | Should Be 'not_applicable'
    $result.value.selected | Should Be $false
    $result.value.reason | Should Be 'operational_route_only'
    @($result.value.capabilities).Count | Should Be 0
  }

  It 'routes the canonical capability labels without requiring upstream skill names' {
    $stateRoot = Join-Path $TestDrive ('absorbed-route-canonical-labels-' + [guid]::NewGuid().ToString('n'))
    $engineering = Invoke-Route $stateRoot 'engineering' 'general_task'
    $engineeringZh = Invoke-Route $stateRoot (U @(24037,31243)) 'general_task'
    $productivity = Invoke-Route $stateRoot 'productivity' 'general_task'
    $grill = Invoke-Route $stateRoot 'grill-me' 'general_task'

    $engineering.exitCode | Should Be 0
    $engineering.value.selected | Should Be $true
    (@($engineering.value.semanticSignals) -contains 'engineering_design') | Should Be $true
    $engineeringZh.exitCode | Should Be 0
    $engineeringZh.value.selected | Should Be $true
    (@($engineeringZh.value.semanticSignals) -contains 'engineering_design') | Should Be $true
    $productivity.value.selected | Should Be $true
    (@($productivity.value.semanticSignals) -contains 'productivity_workflow') | Should Be $true
    $grill.value.selected | Should Be $true
    (@($grill.value.semanticSignals) -contains 'challenge_assumptions') | Should Be $true
  }

  It 'exposes a distinct native parity mapping for every retained Matt source' {
    $stateRoot = Join-Path $TestDrive ('absorbed-parity-map-' + [guid]::NewGuid().ToString('n'))
    $result = Invoke-CapabilityMap $stateRoot
    $matt = @($result.value.capabilities | Where-Object { [string]$_.extensionId -eq 'mattpocock-skills' })
    $tdd = @($matt | Where-Object { $_.name -eq 'tdd' } | Select-Object -First 1)
    $handoff = @($matt | Where-Object { $_.name -eq 'handoff' } | Select-Object -First 1)
    $grill = @($matt | Where-Object { $_.name -eq 'grill-me' } | Select-Object -First 1)
    $prd = @($matt | Where-Object { $_.name -eq 'to-prd' } | Select-Object -First 1)
    $triage = @($matt | Where-Object { $_.name -eq 'triage' } | Select-Object -First 1)

    $result.exitCode | Should Be 0
    $matt.Count | Should Be 17
    @($matt | Where-Object { -not $_.nativeParityMapping -or [string]$_.nativeParityMapping.schema -ne 'super-brain.native-capability-parity.v1' }).Count | Should Be 0
    @($matt | Where-Object { @($_.nativeParityMapping.sourceOutcomes).Count -eq 0 -or @($_.nativeParityMapping.nativeOutcomes).Count -eq 0 -or @($_.nativeParityMapping.enhancements).Count -eq 0 -or @($_.nativeParityMapping.acceptance).Count -eq 0 }).Count | Should Be 0
    $tdd.nativeParityProcedureId | Should Be 'sb.native.engineering.test-strategy.v1'
    $handoff.nativeParityProcedureId | Should Be 'sb.native.h7.handoff.v1'
    $grill.nativeParityProcedureId | Should Be 'sb.native.challenge.gate.v1'
    $prd.nativeParityProcedureId | Should Be 'sb.native.product.prd-synthesis.v1'
    $triage.nativeParityProcedureId | Should Be 'sb.native.product.issue-triage.v1'
    (@($tdd.nativeParityMapping.nativeOutcomes) -join ' ') | Should Match 'focused failing case'
    (@($handoff.nativeParityMapping.nativeOutcomes) -join ' ') | Should Match 'phase, evidence, next action, and return point'
    (@($grill.nativeParityMapping.enhancements) -join ' ') | Should Match 'wins over generic test wording'
    (@($prd.nativeParityMapping.acceptance) -join ' ') | Should Match 'publication target'
    (@($triage.nativeParityMapping.enhancements) -join ' ') | Should Match 'tracker mutation'
  }

  It 'never promotes the legacy Matt router or an adapter-only source as an automatic card' {
    $stateRoot = Join-Path $TestDrive ('absorbed-route-internal-only-' + [guid]::NewGuid().ToString('n'))
    $result = Invoke-Route $stateRoot 'which workflow should I use for this task?' 'general_task'

    (@($result.value.capabilities.name) -contains 'ask-matt') | Should Be $false
    (@($result.value.capabilities.name) -contains 'grilling') | Should Be $false
  }

  It 'keeps the compatibility receipt withheld while exposing compact non-authorizing cards and policy' {
    $stateRoot = Join-Path $TestDrive ('absorbed-route-intent-' + [guid]::NewGuid().ToString('n'))
    $result = Invoke-IntentRoute $stateRoot 'turn this into a PRD requirements specification'

    $result.exitCode | Should Be 0
    $result.value.capabilityRoute.selected | Should Be $true
    $result.value.capabilityRouteWithheld | Should Be $false
    (@($result.value.dispatchHints) -contains 'absorbed_capability_route') | Should Be $true
    (@($result.value.dispatchHints) -contains 'capability_cards_non_authorizing') | Should Be $true
    (@($result.value.dispatchHints) -contains 'native_capability_contract_receipts') | Should Be $true
    (@($result.value.dispatchHints) -contains 'capability_policy_requires_authorization') | Should Be $true
    (@($result.value.absorbedCapabilities.name) -contains 'to-prd') | Should Be $true
    @($result.value.absorbedCapabilities | Where-Object { $_.executionOwner -ne 'super-memory-brain' -or $_.standaloneInstall -ne $false }).Count | Should Be 0
    $receipt = $result.value.capabilityRouteReceipt
    $receipt.schema | Should Be 'super-brain.capability-route-receipt.v1'
    $receipt.state | Should Be 'withheld'
    $receipt.code | Should Be 'CAPABILITY_ROUTE_EVALUATION_WITHHELD'
    (@($receipt.selectedNativeCapabilityIds).Count) | Should Be 0
    (@($receipt.nativeContractIds).Count) | Should Be 0
    (@($receipt.provenanceHashes).Count) | Should Be 0
    (@($receipt.parityHashes).Count) | Should Be 0
    $receipt.shadowGate.schema | Should Be 'super-brain.capability-shadow-gate.v1'
    $receipt.shadowGate.state | Should Be 'withheld'
    $receipt.shadowGate.code | Should Be 'H7_CAPABILITY_ACTIVATION_SHADOW_WITHHELD'
    $receipt.shadowGate.activationAllowed | Should Be $false
    ($receipt.shadowGate.selectedContractCount -gt 0) | Should Be $true
    $receipt.routeHash | Should Match '^[a-f0-9]{64}$'
    $receipt.nonAuthorizing | Should Be $true
    $receipt.rawPromptStored | Should Be $false
    $receipt.rawTranscriptStored | Should Be $false
    $receipt.sourcePathsOmitted | Should Be $true
    ($receipt.PSObject.Properties.Name -contains 'sourcePath') | Should Be $false
    ($receipt.PSObject.Properties.Name -contains 'query') | Should Be $false
    ($receipt.PSObject.Properties.Name -contains 'input') | Should Be $false
  }

  It 'rejects the legacy extension selector before it can refresh a standalone host skill' {
    $hostRoot = Join-Path $TestDrive ('absorbed-host-boundary-' + [guid]::NewGuid().ToString('n'))
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HotRefresh -SkillRoots $hostRoot -Extensions 'mattpocock-skills' -ReportOnly -SkipGlobalStartup -Json 2>&1)
    $exitCode = $LASTEXITCODE
    $result = (($raw -join "`n") | ConvertFrom-Json)

    $exitCode | Should Be 1
    $result.ok | Should Be $false
    $result.error | Should Match 'ABSORBED_PROVENANCE_ONLY_NO_STANDALONE_INSTALL'
    $result.results[0].action | Should Be 'reject-extension-host-selector'
    $result.results[0].message | Should Match 'package-owned cold provenance only'
    Test-Path -LiteralPath $hostRoot | Should Be $false
  }
}
