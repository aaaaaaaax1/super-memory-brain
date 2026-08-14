$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'

function Invoke-CanonicalSourceContract([hashtable]$Parameters) {
  $bound = @{}
  foreach ($key in $Parameters.Keys) { $bound[$key] = $Parameters[$key] }
  $bound.NoExit = $true
  $bound.Json = $true
  $raw = @(& $contractScript @bound 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode=if($value -and $value.ok -eq $true){0}else{1}; value=$value; text=$text }
}

function Write-CanonicalSourceJson([string]$Path,[object]$Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Get-CanonicalSourceHash([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-CanonicalSourceIntentJson {
  return ([pscustomobject]@{
    schema='super-brain.intent-contract.v2'
    literalRequestDigest='keep an editable local notebook behind governed commands'
    resolvedOutcome='Users can edit local notebook entries and receive a task-scoped receipt.'
    productRole='local notebook UI backed by a governed command API'
    integrationObligations=@('local UI','governed command API','task receipt')
    materialUnknowns=@()
    compatibilityGuards=@('no browser-side direct database writes')
    preservedCapabilities=@('editable notebook')
    acceptanceCriteria=@('an edit produces a receipt')
    governedEquivalent='receipt-bound local command editing'
    autonomyTier='align'
    integrationMap=[pscustomobject]@{
      entryPoint='notebook page';userFlow='open note, edit, save, observe receipt';domainOwner='command engine';stateOwner='local state authority'
      downstreamConsumers=@('notebook projection');failureRecovery='CAS conflict preserves the draft';privacyPerformance='loopback only and bounded payloads'
      compatibilityMigration='legacy records remain readable';verification='command API regression';completionCondition='edit and rollback paths are verified'
    }
    investigationEvidence=@('runtime/brain_control.py command authority')
    materialBranches=@()
    focusedQuestion=''
    preserveExistingFlow=$true
    replacementReceipt=''
    componentResolution=[pscustomobject]@{requestedComponent='direct editor';resolvedComponent='governed command API';outcomePreserved=$true;reason='preserves editing with receipts'}
  } | ConvertTo-Json -Compress)
}

function New-CanonicalSourceFixture([string]$StateRoot,[string]$TaskId,[string]$IntentContractJson = '') {
  $workspaceKey = 'ws-source-4242424242424242'
  $sessionKey = 'sid-source-4242424242424242'
  $createArguments = @{
    Action='Set';TaskId=$TaskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey
    FocusId='source-main';FocusLabel='Source-bound main';InstructionMode='continue'
    LatestUserInstruction='approve a source-bound canonical plan';NextAction='execute A'
    PendingSteps=@('A','B');EnableCanonicalPlan=$true;RequireStructuralGuards=$true
    StateRoot=$StateRoot;Source='CanonicalPlanSourceBinding.Tests.ps1'
  }
  if (-not [string]::IsNullOrWhiteSpace($IntentContractJson)) { $createArguments.IntentContractJson = $IntentContractJson }
  $created = Invoke-CanonicalSourceContract $createArguments
  $created.exitCode | Should Be 0

  $sourceRoot = Join-Path $StateRoot 'canonical-sources'
  $planPath = Join-Path $sourceRoot 'plans\canonical-plan.md'
  $manifestPath = Join-Path $sourceRoot 'receipts\canonical-plan-source.json'
  $planBody = '# Canonical plan' + [Environment]::NewLine + '- A' + [Environment]::NewLine + '- B' + [Environment]::NewLine
  $planDir = Split-Path -Parent $planPath
  if (-not (Test-Path -LiteralPath $planDir)) { New-Item -ItemType Directory -Force -Path $planDir | Out-Null }
  [IO.File]::WriteAllText($planPath,$planBody,[Text.UTF8Encoding]::new($false))
  $manifest = [pscustomobject]@{
    schema='super-brain.canonical-plan-source.v1'
    planId=[string]$created.value.canonicalPlan.planId
    generation=[int]$created.value.canonicalPlan.generation
    currentFingerprint=[string]$created.value.canonicalPlan.currentFingerprint
    sourceDocument=[pscustomobject]@{
      relativePath='plans/canonical-plan.md'
      sha256=Get-CanonicalSourceHash $planPath
    }
  }
  Write-CanonicalSourceJson $manifestPath $manifest
  return [pscustomobject]@{
    stateRoot=$StateRoot
    taskId=$TaskId
    workspaceKey=$workspaceKey
    sessionKey=$sessionKey
    created=$created.value
    planPath=$planPath
    manifestPath=$manifestPath
  }
}

Describe 'Canonical plan source binding' {
  It 'explicitly retires public package docs as canonical-source evidence' {
    $stateRoot = Join-Path $TestDrive 'package-docs-retired'
    $packageDocs = Join-Path $root 'docs\evidence\retired-source.json'
    $result = Invoke-CanonicalSourceContract @{
      Action='Set';TaskId='task-package-docs-retired';WorkspaceKey='ws-source-retired-424242424242';SessionKey='sid-source-retired-424242424242'
      FocusId='source-main';InstructionMode='continue';LatestUserInstruction='bind a retired public source';NextAction='reject retired source'
      PendingSteps=@('A');EnableCanonicalPlan=$true;RequireStructuralGuards=$true;CanonicalSourceManifestPath=$packageDocs
      StateRoot=$stateRoot;Source='CanonicalPlanSourceBinding.Tests.ps1'
    }
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_SOURCE_PACKAGE_DOCS_RETIRED'
  }

  It 'permits a new strict plan only when it is explicitly initialized as withheld for reconciliation' {
    $stateRoot = Join-Path $TestDrive 'strict-initialization'
    $created = Invoke-CanonicalSourceContract @{
      Action='Set';TaskId='task-source-strict-initialization';WorkspaceKey='ws-source-init-424242424242';SessionKey='sid-source-init-424242424242'
      FocusId='source-main';InstructionMode='continue';LatestUserInstruction='create a reconciled canonical plan';NextAction='reconcile canonical source'
      PendingSteps=@('A','B');EnableCanonicalPlan=$true;RequireStructuralGuards=$true
      RequireCanonicalPlanSource=$true;RequiresReconciliation=$true
      StateRoot=$stateRoot;Source='CanonicalPlanSourceBinding.Tests.ps1'
    }
    $created.exitCode | Should Be 0
    $created.value.canonicalPlanSourceRequired | Should Be $true
    $created.value.needsReconciliation | Should Be $true

    $resolved = Invoke-CanonicalSourceContract @{
      Action='Resolve';TaskId='task-source-strict-initialization';WorkspaceKey='ws-source-init-424242424242';SessionKey='sid-source-init-424242424242'
      StateRoot=$stateRoot
    }
    $resolved.exitCode | Should Be 0
    $resolved.value.actionAuthorization | Should Be 'withheld'
    $resolved.value.canonicalPlanSource.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_SOURCE_REQUIRED'
  }

  It 'freezes an explicitly migrated legacy canonical plan until a source receipt is bound' {
    $fixture = New-CanonicalSourceFixture (Join-Path $TestDrive 'strict-missing-source') 'task-source-strict-missing'
    $observed = Invoke-CanonicalSourceContract @{
      Action='ObserveUser';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      UserInstruction='reconcile this approved canonical plan before continuing'
      RequiresReconciliation=$true;RequireCanonicalPlanSource=$true
      StateRoot=$fixture.stateRoot
    }
    $observed.exitCode | Should Be 0
    $observed.value.canonicalPlanSourceRequired | Should Be $true

    $resolved = Invoke-CanonicalSourceContract @{
      Action='Resolve';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      StateRoot=$fixture.stateRoot
    }
    $resolved.exitCode | Should Be 0
    $resolved.value.actionAuthorization | Should Be 'withheld'
    $resolved.value.canonicalPlanSource.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_SOURCE_REQUIRED'
  }

  It 'withholds both resolve and guard when the bound plan document changes' {
    $fixture = New-CanonicalSourceFixture (Join-Path $TestDrive 'document-drift') 'task-source-document-drift'
    $bound = Invoke-CanonicalSourceContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='source-main';InstructionMode='continue';LatestUserInstruction='bind the verified canonical source';NextAction='execute A'
      ExpectedRevision=[int]$fixture.created.revision;ExpectedPlanFingerprint=[string]$fixture.created.planReceipt.planFingerprint
      TransitionId='bind-source-once';CanonicalSourceManifestPath=$fixture.manifestPath;RequireCanonicalPlanSource=$true
      StateRoot=$fixture.stateRoot;Source='CanonicalPlanSourceBinding.Tests.ps1'
    }
    $bound.exitCode | Should Be 0
    $bound.value.canonicalPlanSourceRequired | Should Be $true

    $healthy = Invoke-CanonicalSourceContract @{
      Action='Resolve';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      StateRoot=$fixture.stateRoot
    }
    $healthy.exitCode | Should Be 0
    $healthy.value.actionAuthorization | Should Be 'allowed'
    $healthy.value.canonicalPlanSource.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_SOURCE_CURRENT'

    $driftBody = '# Canonical plan' + [Environment]::NewLine + '- A' + [Environment]::NewLine + '- B' + [Environment]::NewLine + '- drift' + [Environment]::NewLine
    [IO.File]::WriteAllText($fixture.planPath,$driftBody,[Text.UTF8Encoding]::new($false))
    $drifted = Invoke-CanonicalSourceContract @{
      Action='Resolve';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      StateRoot=$fixture.stateRoot
    }
    $drifted.exitCode | Should Be 0
    $drifted.value.actionAuthorization | Should Be 'withheld'
    $drifted.value.canonicalPlanSource.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_SOURCE_DOCUMENT_HASH_MISMATCH'

    $guard = Invoke-CanonicalSourceContract @{
      Action='Guard';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      ProposedWorkId='source-main';StateRoot=$fixture.stateRoot
    }
    $guard.exitCode | Should Be 1
    $guard.value.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_SOURCE_DOCUMENT_HASH_MISMATCH'
  }

  It 'refreshes the intent receipt when a canonical source binding changes the revision' {
    $fixture = New-CanonicalSourceFixture (Join-Path $TestDrive 'source-intent-refresh') 'task-source-intent-refresh' (New-CanonicalSourceIntentJson)
    $bound = Invoke-CanonicalSourceContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='source-main';InstructionMode='continue';LatestUserInstruction='bind the verified canonical source'
      NextAction='execute A';ExpectedRevision=[int]$fixture.created.revision;ExpectedPlanFingerprint=[string]$fixture.created.planReceipt.planFingerprint
      TransitionId='bind-source-with-intent-once';CanonicalSourceManifestPath=$fixture.manifestPath;RequireCanonicalPlanSource=$true
      StateRoot=$fixture.stateRoot;Source='CanonicalPlanSourceBinding.Tests.ps1'
    }
    $bound.exitCode | Should Be 0

    $resolved = Invoke-CanonicalSourceContract @{
      Action='Resolve';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      StateRoot=$fixture.stateRoot
    }
    $resolved.exitCode | Should Be 0
    $resolved.value.actionAuthorization | Should Be 'allowed'
    $resolved.value.intentReceipt.code | Should Be 'EXECUTION_CONTRACT_INTENT_RECEIPT_CURRENT'
  }

  It 'rebinds the original intent across sessions while stale canonical source still withholds execution' {
    $fixture = New-CanonicalSourceFixture (Join-Path $TestDrive 'rebind-stale-source') 'task-source-rebind-stale' (New-CanonicalSourceIntentJson)
    $bound = Invoke-CanonicalSourceContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='source-main';InstructionMode='continue';LatestUserInstruction='bind a verified canonical source before controlled work'
      NextAction='execute A';ExpectedRevision=[int]$fixture.created.revision;ExpectedPlanFingerprint=[string]$fixture.created.planReceipt.planFingerprint
      TransitionId='bind-source-before-rebind';CanonicalSourceManifestPath=$fixture.manifestPath;RequireCanonicalPlanSource=$true
      StateRoot=$fixture.stateRoot;Source='CanonicalPlanSourceBinding.Tests.ps1'
    }
    $bound.exitCode | Should Be 0

    $stale = Get-Content -LiteralPath $bound.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $stale.canonicalPlanSource.currentFingerprint = 'stale-source-fingerprint'
    $stale.intentResolutionReceipt.contractRevision = 0
    Write-CanonicalSourceJson $bound.value.path $stale
    $newSession = 'sid-source-rebind-4242424242'

    $rebound = Invoke-CanonicalSourceContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$newSession;RebindSession=$true
      FocusId='source-main';InstructionMode='continue';LatestUserInstruction='recover the original task ownership before reconciling its stale source'
      NextAction='reconcile the stale canonical source';ExpectedRevision=[int]$bound.value.revision
      ExpectedPlanFingerprint=[string]$bound.value.planReceipt.planFingerprint
      TransitionId='rebind-stale-source-owner';StateRoot=$fixture.stateRoot;Source='CanonicalPlanSourceBinding.Tests.ps1'
    }
    $resolved = Invoke-CanonicalSourceContract @{
      Action='Resolve';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$newSession;StateRoot=$fixture.stateRoot
    }

    $rebound.exitCode | Should Be 0
    $rebound.value.ownerSessionKey | Should Not Be $bound.value.ownerSessionKey
    $rebound.value.intentSessionRebindReceipt.newOwnerSessionKey | Should Be $rebound.value.ownerSessionKey
    $resolved.exitCode | Should Be 0
    $resolved.value.actionAuthorization | Should Be 'withheld'
    $resolved.value.canonicalPlanSource.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_SOURCE_PLAN_MISMATCH'
  }
}
