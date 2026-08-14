$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'H7TestFixture.ps1')

function New-PackageVersionRebindFixture([string]$Name) {
  $fixtureRoot = Join-Path $TestDrive $Name
  $packageRoot = Join-Path $fixtureRoot 'CORE'
  New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
  # Copy the executable control plane only.  CORE\memory is a private-state
  # junction in a real checkout and may contain long historical paths; a
  # rebind fixture must not traverse or duplicate it.
  Get-ChildItem -LiteralPath $root -File | Copy-Item -Destination $packageRoot -Force
  foreach ($directory in @('scripts','runtime')) {
    Copy-Item -LiteralPath (Join-Path $root $directory) -Destination (Join-Path $packageRoot $directory) -Recurse -Force
  }
  return [pscustomobject]@{
    fixtureRoot = $fixtureRoot
    packageRoot = $packageRoot
    contractScript = Join-Path $packageRoot 'scripts\execution-contract.ps1'
    stateRoot = Join-Path $fixtureRoot 'state'
    projectRoot = $fixtureRoot
  }
}

function Set-PackageFixtureVersion([string]$ManifestPath,[string]$Version) {
  $text = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
  $text = [regex]::Replace($text,'"version"\s*:\s*"[^"]+"',('"version": "' + $Version + '"'),1)
  [IO.File]::WriteAllText($ManifestPath,$text,[Text.UTF8Encoding]::new($false))
}

function Get-PackageFixtureVersion([string]$ManifestPath) {
  return [string]((Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).version)
}

function Get-NextPackageFixtureVersion([string]$Version) {
  if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "Invalid fixture package version: $Version" }
  return "$($Matches[1]).$($Matches[2]).$([int]$Matches[3] + 1)"
}

function New-PackageVersionRebindContract([object]$Fixture,[string]$TaskId) {
  return Invoke-H7FixtureContractScript $Fixture.contractScript $Fixture.packageRoot @(
    '-Action','Set','-TaskId',$TaskId,'-WorkspaceKey','ws-package-rebind-20260814',
    '-SessionKey','sid-package-rebind-20260814','-FocusId','release-v060',
    '-InstructionMode','continue','-LatestUserInstruction','complete the approved v0.6.0 release',
    '-CurrentPhase','CORE migration Stage 4','-CurrentStep','release migration is ready',
    '-NextAction','run release gates and bump v0.6.0','-CompletedSteps','CORE layout migration',
    '-PendingSteps','run release gates and bump v0.6.0','-ProjectRoot',$Fixture.projectRoot,
    '-StateRoot',$Fixture.stateRoot,'-Json'
  )
}

function Invoke-PackageVersionRebind([object]$Fixture,[object]$Contract,[string]$TaskId,[string]$FromPackageVersion) {
  return Invoke-H7FixtureContractScript $Fixture.contractScript $Fixture.packageRoot @(
    '-Action','RebindPackageVersion','-TaskId',$TaskId,
    '-WorkspaceKey','ws-package-rebind-20260814','-SessionKey','sid-package-rebind-20260814',
    '-FromPackageVersion',$FromPackageVersion,'-ExpectedRevision',[string]$Contract.revision,
    '-ExpectedPlanFingerprint',[string]$Contract.planReceipt.planFingerprint,
    '-ExpectedVisibleProgressReceiptHash',[string]$Contract.visibleProgressReceipt.payloadHash,
    '-TransitionId','package-version-rebind-v060','-ProjectRoot',$Fixture.projectRoot,
    '-StateRoot',$Fixture.stateRoot,'-Json'
  )
}

Describe 'H7 package-version rebind' {
  It 'migrates exactly one verified task across the manifest version boundary and rebuilds its H7 receipt' {
    $fixture = New-PackageVersionRebindFixture 'rebind-success'
    $taskId = 'task-package-version-rebind-success'
    $manifestPath = Join-Path $fixture.packageRoot 'manifest.json'
    $fromVersion = Get-PackageFixtureVersion $manifestPath
    $toVersion = Get-NextPackageFixtureVersion $fromVersion
    $set = New-PackageVersionRebindContract $fixture $taskId
    $set.exitCode | Should Be 0
    $set.value.packageVersion | Should Be $fromVersion

    Set-PackageFixtureVersion $manifestPath $toVersion
    $rebound = Invoke-PackageVersionRebind $fixture $set.value $taskId $fromVersion

    $rebound.exitCode | Should Be 0
    $rebound.value.packageVersion | Should Be $toVersion
    $rebound.value.revision | Should Be ([int]$set.value.revision + 1)
    $rebound.value.currentPhase | Should Be $set.value.currentPhase
    $rebound.value.currentStep | Should Be $set.value.currentStep
    $rebound.value.nextAction | Should Be $set.value.nextAction
    $rebound.value.lastConfirmedSentence | Should Be $set.value.lastConfirmedSentence
    $rebound.value.visibleProgressReceipt.payloadHash | Should Not Be $set.value.visibleProgressReceipt.payloadHash
    $rebound.value.packageVersionRebind.fromVersion | Should Be $fromVersion
    $rebound.value.packageVersionRebind.toVersion | Should Be $toVersion

    $current = Invoke-H7FixtureContractScript $fixture.contractScript $fixture.packageRoot @(
      '-Action','Get','-TaskId',$taskId,'-WorkspaceKey','ws-package-rebind-20260814',
      '-SessionKey','sid-package-rebind-20260814','-StateRoot',$fixture.stateRoot,'-Json'
    )
    $current.exitCode | Should Be 0
    $current.value.packageVersion | Should Be $toVersion
    $current.value.visibleProgressReceipt.payloadHash | Should Be $rebound.value.visibleProgressReceipt.payloadHash
  }

  It 'fails closed when evidence other than the allowed manifest identity changed before rebind' {
    $fixture = New-PackageVersionRebindFixture 'rebind-unexpected-drift'
    $taskId = 'task-package-version-rebind-drift'
    $manifestPath = Join-Path $fixture.packageRoot 'manifest.json'
    $fromVersion = Get-PackageFixtureVersion $manifestPath
    $toVersion = Get-NextPackageFixtureVersion $fromVersion
    $set = New-PackageVersionRebindContract $fixture $taskId
    $set.exitCode | Should Be 0
    Set-PackageFixtureVersion $manifestPath $toVersion

    $evidence = Get-ChildItem -LiteralPath $fixture.projectRoot -Filter 'h7-fixture-evidence-*.txt' -File | Select-Object -First 1
    [IO.File]::AppendAllText($evidence.FullName,'unexpected source change',[Text.UTF8Encoding]::new($false))
    $rebound = Invoke-PackageVersionRebind $fixture $set.value $taskId $fromVersion

    $rebound.exitCode | Should Be 1
    $rebound.value.code | Should Be 'EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_UNEXPECTED_EVIDENCE_DRIFT'
  }
}
