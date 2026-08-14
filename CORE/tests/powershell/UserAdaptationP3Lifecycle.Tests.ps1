$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'scripts\common.ps1')
. (Join-Path $Root 'scripts\internal\user-adaptation-core.ps1')

function Write-P3AdaptationJson([string]$Path, $Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  Write-JsonUtf8NoBom $Path $Value 20
}

function Initialize-P3AdaptationStore([string]$Workspace, [object[]]$Candidates = @(), [object[]]$Tombstones = @()) {
  $paths = Get-UserAdaptationPaths $Root $Workspace
  $store = [pscustomobject]@{
    schema='super-brain.user-adaptation-store.v2';revision=1;generation=1;enabled=$true;policyHash=(Get-UserAdaptationPolicyHash $Root)
    migrationId='';migrationTransitionId='';migrationPayloadHash='';sourceBindingHash='';migrationComplete=$true;migratedFrom='test';migratedAt='2026-07-28T00:00:00Z';updatedAt='2026-07-28T00:00:00Z'
    observations=@();candidates=@($Candidates);profile=@();tombstones=@($Tombstones);legacyPreferenceHashes=@();receipts=@();profilePressure='ok';rawPromptStored=$false
  }
  Write-P3AdaptationJson $paths.storeV2 $store
  return $paths
}

Describe 'P3 user adaptation lifecycle visibility' {
  It 'reports bounded validated-candidate evidence without claiming objective improvement' {
    $workspace = Join-Path $TestDrive 'validated-visibility'
    $candidate = [pscustomobject]@{
      candidateId='candidate-1234567890abcdef';preferenceId='pref-1234567890abcdef';identityHash=('a' * 32);identityGeneration=1;scope='project';scopeKey='ws-p3-validated-001';habitKey='response_detail';value='concise';status='staged';rawPromptStored=$false
      validation=[pscustomobject]@{status='validated';scopedEvidence=$true;minimumSupportMet=$true;distinctTasksMet=$true;distinctContextsMet=$true;contradictionGuardMet=$true;confidenceGuardMet=$true;overfitGuardPassed=$true;validatedAt='2026-07-28T00:00:00Z';rawPromptStored=$false}
    }
    Initialize-P3AdaptationStore $workspace @($candidate) | Out-Null

    $status = Get-UserAdaptationStatusV2 $Root $workspace
    $evolution = Get-UserAdaptationEvolutionV2 $Root $workspace

    $status.validatedCandidateCount | Should Be 1
    $evolution.currentState.validatedCandidates | Should Be 1
    $evolution.retainedChangeCounts.validatedCandidates | Should Be 1
    $evolution.evaluation.status | Should Be 'not_scored'
    $evolution.evaluation.improvementClaimAllowed | Should Be $false
  }

  It 'records a confirmed reinstate as an identity lifecycle event without reviving a preference' {
    $workspace = Join-Path $TestDrive 'reinstate-event'
    $identity = Get-UserAdaptationIdentity 'project' 'ws-p3-reinstate-001' 'response_detail'
    $tombstone = [pscustomobject]@{identityHash=[string]$identity.hash;forgottenThroughGeneration=1;currentGeneration=1;forgottenAt='2026-07-28T00:00:00Z';reinstatedAt='';rawPromptStored=$false}
    Initialize-P3AdaptationStore $workspace @() @($tombstone) | Out-Null

    $result = Invoke-UserAdaptationReinstateV2 -Root $Root -Scope project -ScopeKey 'ws-p3-reinstate-001' -HabitKey response_detail -WorkspaceRoot $workspace -ExpectedRevision 1 -TransitionId 'p3-reinstate-001' -Confirmed
    $evolution = Get-UserAdaptationEvolutionV2 $Root $workspace

    $result.ok | Should Be $true
    $evolution.retainedChangeCounts.reinstated | Should Be 1
    @($evolution.recentChanges | Where-Object { $_.entityType -eq 'identity' -and $_.toStatus -eq 'reinstated' }).Count | Should Be 1
    $evolution.currentState.activePreferences | Should Be 0
  }
}
