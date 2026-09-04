$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Core = Join-Path $Root 'scripts\internal\user-adaptation-core.ps1'
$Hook = Join-Path $Root 'scripts\codex-user-prompt-hook.ps1'
$Preflight = Join-Path $Root 'scripts\cognitive-preflight.ps1'
$Maintenance = Join-Path $Root 'scripts\post-task-maintenance.ps1'
$Observer = Join-Path $Root 'scripts\user-adaptation-observer.ps1'
$TaskVerification = Join-Path $Root 'scripts\task-verification.ps1'
$ReflectionPromotion = Join-Path $Root 'scripts\reflection-promotion.ps1'
$ExperienceWriter = Join-Path $Root 'scripts\write-experience.ps1'

. (Join-Path $Root 'scripts\common.ps1')
. $Core
. (Join-Path $PSScriptRoot 'UserAdaptationConfirmationReceipt.Fixture.ps1')

function Add-TestAdaptationObservation {
  param(
    [string]$WorkspaceRoot,
    [string]$HabitKey,
    [string]$Value,
    [string]$TaskId,
    [string]$Context = 'general',
    [string]$Signal = 'Support',
    [string]$Source = 'repeated_behavior',
    [string]$Scope = 'global',
    [string]$ScopeKey = '',
    [string]$EvidenceRef = ''
  )
  $paths=Get-UserAdaptationPaths $Root $WorkspaceRoot
  if(-not(Test-Path -LiteralPath $paths.storeV2 -PathType Leaf)){$null=Initialize-TestV2AdaptationStore $WorkspaceRoot}
  $revision=[int](Get-UserAdaptationStatus $Root $WorkspaceRoot).revision
  $transition='legacy-helper-'+(Get-UserAdaptationHash "$TaskId|$Scope|$ScopeKey|$HabitKey|$Value|$Signal|$EvidenceRef" 8)
  if($Source-eq'repeated_behavior'){
    $evidenceDate=if($TaskId-match'(\d+)$'-and([int]$Matches[1]%2)-eq1){'2026-07-21'}else{'2026-07-20'}
    $verifiedScope=if($Scope-eq'global'){'project'}else{$Scope}
    $verifiedScopeKey=if($Scope-eq'global'){'ws-eeeeeeeeeeeeeeeeeeeeeeee'}else{$ScopeKey}
    return Add-TestV2VerifiedObservation -WorkspaceRoot $WorkspaceRoot -HabitKey $HabitKey -Value $Value -Scope $verifiedScope -ScopeKey $verifiedScopeKey -Context $Context -TaskId $TaskId -ExpectedRevision $revision -EvidenceDate $evidenceDate -TransitionId $transition -Signal $Signal
  }
  return Add-UserAdaptationObservation -Root $Root -HabitKey $HabitKey -Value $Value -TaskId $TaskId -Context $Context -Signal $Signal -Source $Source -Scope $Scope -ScopeKey $ScopeKey -EvidenceRef $EvidenceRef -WorkspaceRoot $WorkspaceRoot -EvidenceKind durable_explicit -Producer trusted_direct_statement -ExpectedRevision $revision -TransitionId $transition
}

function Set-TestAdaptationPreference {
  param(
    [string]$WorkspaceRoot,
    [string]$HabitKey,
    [string]$Value,
    [string]$Scope = 'global',
    [string]$ScopeKey = '',
    [string]$Context = 'general',
    [string]$TaskId = 'explicit-test'
  )
  $observation = Add-TestAdaptationObservation -WorkspaceRoot $WorkspaceRoot -HabitKey $HabitKey -Value $Value -TaskId $TaskId -Context $Context -Source explicit_user -Scope $Scope -ScopeKey $ScopeKey -EvidenceRef "$TaskId|$Scope|$ScopeKey|$HabitKey|$Value"
  Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $WorkspaceRoot -ExpectedRevision ([int]$observation.revision) -TransitionId ('legacy-helper-synthesis-'+(Get-UserAdaptationHash "$TaskId|$Scope|$ScopeKey|$HabitKey|$Value" 8))
}

function Invoke-TestAdaptationSynthesis([string]$WorkspaceRoot) {
  $revision=[int](Get-UserAdaptationStatus $Root $WorkspaceRoot).revision
  return Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $revision -TransitionId ("test-synthesis-$revision")
}

function Write-TestAdaptationJson([string]$Path, $Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  Write-JsonUtf8NoBom $Path $Value 12
}

function Write-TestAdaptationVerificationArtifact {
  param(
    [string]$WorkspaceRoot,[string]$TaskId,[string]$WorkspaceKey,
    [string[]]$Signals=@(),[string[]]$Measurements=@(),[string]$Source='accepted_outcome',[string]$Context='coding',[string]$WorkflowKey='',
    [string]$CorrectionCandidateId='',[string]$CorrectionTargetPreferenceId='',[string]$CheckedAt=''
  )
  $outcomeRoot=Join-Path $WorkspaceRoot 'runtime-state\verified-task-outcomes'
  $safeTask=(($TaskId-replace'[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  $outcomePath=Join-Path $outcomeRoot ($safeTask+'.json')
  $ownerSessionKey='sid-adaptation-evidence'
  $artifactBinding=New-SuperBrainEvidenceBinding -TaskId $TaskId -WorkspaceKey $WorkspaceKey -OwnerSessionKey $ownerSessionKey -Root $Root
  $verificationPath=Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'runtime-state\task-verifications') $TaskId '.json'
  Write-TestAdaptationJson $verificationPath ([pscustomobject]@{schema='super-brain.task-verification.v1';ok=$true;taskId=$TaskId;workspaceKey=$WorkspaceKey;evidenceBinding=$artifactBinding})
  $completionBinding=[pscustomobject]@{schema=[string]$artifactBinding.schema;packageVersion=[string]$artifactBinding.packageVersion;gitTreeHash=[string]$artifactBinding.gitTreeHash;treeAlgorithm=[string]$artifactBinding.treeAlgorithm;gitHeadTreeHash=[string]$artifactBinding.gitHeadTreeHash;taskId=[string]$artifactBinding.taskId;workspaceKey=[string]$artifactBinding.workspaceKey;ownerSessionKey=[string]$artifactBinding.ownerSessionKey;artifactHash=(Get-SuperBrainFileSha256 $verificationPath);artifactKind='task_verification'}
  Write-TestAdaptationJson (Join-Path $WorkspaceRoot "runtime-state\checkpoints\completed\$safeTask.json") ([pscustomobject]@{schema='super-brain.checkpoint.v1';taskId=$TaskId;status='completed';source='task-verification.ps1'})
  $projectionPath=Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'task-state-store\projections') $TaskId '.json'
  Write-TestAdaptationJson $projectionPath ([pscustomobject]@{schema='super-brain.task-state-projection.v2';taskId=$TaskId;revision=1;lifecycle=[pscustomobject]@{status='completed';ownerSessionKey=$ownerSessionKey;evidenceBinding=$completionBinding}})
  $outcome=[pscustomobject]@{
    schema='super-brain.verified-task-outcome.v1';recordId=('verified-task-'+$safeTask);taskId=$TaskId;workspaceKey=$WorkspaceKey;source='task-verification.ps1';packageVersion=[string](Get-SuperBrainManifest $Root).version;recordedAt='2026-07-22T00:00:00Z'
    verification=[pscustomobject]@{ok=$true;taskScopedGuardOk=$true;realUserPathVerified=$true;completedCheckpointVerified=$true;evidenceBindingCurrent=$true;packageVerificationOk=$true;hotRefreshOk=$true}
    classification=[pscustomobject]@{verifiedRealWorldTask=$true;verifiedAutonomyScenario=$false};correctionCandidateId=$CorrectionCandidateId;evidenceBinding=$completionBinding;privacy=[pscustomobject]@{rawPromptStored=$false;rawSummaryStored=$false}
  }
  Write-TestAdaptationJson $outcomePath $outcome
  $outcomeHash=Get-SuperBrainFileSha256 $outcomePath
  $outcomeSnapshotRoot=Join-Path $WorkspaceRoot 'runtime-state\user-adaptation-outcomes';if(-not(Test-Path -LiteralPath $outcomeSnapshotRoot)){New-Item -ItemType Directory -Force -Path $outcomeSnapshotRoot|Out-Null};$outcomeSnapshot=Join-Path $outcomeSnapshotRoot ((Get-SuperBrainCanonicalTaskToken $TaskId)+'--'+$outcomeHash+'.json')
  if(-not(Test-Path -LiteralPath $outcomeSnapshot)){Copy-Item -LiteralPath $outcomePath -Destination $outcomeSnapshot}
  $request=[pscustomobject]@{source=$Source;context=$Context;workflowKey=$WorkflowKey.ToLowerInvariant();signals=@($Signals|ForEach-Object{([string]$_).ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique);measurements=@($Measurements|ForEach-Object{(([string]$_)-replace'\s+','').ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique);correctionCandidateId=$CorrectionCandidateId;correctionTargetPreferenceId=$CorrectionTargetPreferenceId;rawPromptStored=$false}
  $confirmation=$null
  if($Source-eq'accepted_outcome'){
    $signalObjects=@($Signals|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{$parts=([string]$_).Split('=',2);[pscustomobject]@{habitKey=$parts[0];value=$parts[1]}})
    $protocol=$null
    $measurementValues=@($Measurements|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)})
    if($measurementValues.Count-gt0){$normalized=(([string]$measurementValues[0])-replace'\s+','').ToLowerInvariant();if($normalized-match'^review_protocol=multi_pass;forwardpasses=([1-5]);reversepasses=([0-3]);riskfloor=(workflow|structural)(?:;contexts=([a-z,]+))?$'){$protocol=[pscustomobject]@{forwardPasses=[int]$Matches[1];reversePasses=[int]$Matches[2];riskFloor=[string]$Matches[3]};if(-not[string]::IsNullOrWhiteSpace([string]$Matches[4])){$protocol|Add-Member -NotePropertyName contexts -NotePropertyValue @(([string]$Matches[4]-split',')|Sort-Object -Unique) -Force}}}
    $confirmation=New-TestUserAdaptationConfirmationReceiptFixture -Root $Root -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -TaskInstanceId 'ti-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -WorkspaceKey $WorkspaceKey -OwnerSessionKey 'sid-testconfirmation' -ContractRevision 1 -PlanFingerprint ('1'*16) -PlanId 'plan-test-confirmation' -PlanGeneration 1 -PlanOriginFingerprint ('2'*16) -CanonicalFingerprint ('3'*16) -Context $Context -Scope $(if([string]::IsNullOrWhiteSpace($WorkflowKey)){'project'}else{'workflow'}) -WorkflowKey $WorkflowKey -Signals $signalObjects -ProtocolBinding $protocol -InstructionSha256 (Get-SuperBrainStableHash "$TaskId|$Context|$WorkflowKey|$(@($Signals)-join',')|$(@($Measurements)-join',')" 64)
  }
  $artifactCheckedAt=if([string]::IsNullOrWhiteSpace($CheckedAt)){'2026-07-22T00:00:00Z'}else{$CheckedAt}
  $artifact=[pscustomobject]@{
    schema='super-brain.user-adaptation-verification.v2';source='task-verification.ps1';packageVersion=[string](Get-SuperBrainManifest $Root).version;checkedAt=$artifactCheckedAt;taskId=$TaskId;workspaceKey=$WorkspaceKey;eligibleForAdaptation=$true
    verification=[pscustomobject]@{ok=$true;taskScopedGuardOk=$true;realUserPathVerified=$true};completion=[pscustomobject]@{completed=$true;transactionId=('completion-'+$safeTask);taskStateRevision=2}
    verifiedOutcome=[pscustomobject]@{recordId=[string]$outcome.recordId;relativePath=('runtime-state/user-adaptation-outcomes/'+[IO.Path]::GetFileName($outcomeSnapshot));sha256=$outcomeHash};confirmationReceipt=if($confirmation){[pscustomobject]@{relativePath=[string]$confirmation.relativePath;sha256=[string]$confirmation.sha256;selectionHash=[string]$confirmation.selectionHash}}else{$null};request=$request;requestHash=(Get-SuperBrainStableHash ($request|ConvertTo-Json -Depth 8 -Compress) 64);rawPromptStored=$false;rawSummaryStored=$false
  }
  $artifactRoot=Join-Path $WorkspaceRoot 'runtime-state\user-adaptation-verifications'
  $pending=Join-Path $artifactRoot ('.pending-'+[guid]::NewGuid().ToString('n')+'.json')
  Write-TestAdaptationJson $pending $artifact
  $artifactHash=Get-SuperBrainFileSha256 $pending
  $artifactPath=Join-Path $artifactRoot ((Get-SuperBrainCanonicalTaskToken $TaskId)+'--'+$artifactHash+'.json')
  if(Test-Path -LiteralPath $artifactPath){Remove-Item -LiteralPath $pending -Force}else{Move-Item -LiteralPath $pending -Destination $artifactPath}
  return [pscustomobject]@{path=$artifactPath;sha256=$artifactHash;outcomePath=$outcomePath;outcomeSha256=$outcomeHash;confirmationPath=if($confirmation){[string]$confirmation.path}else{''};confirmationSha256=if($confirmation){[string]$confirmation.sha256}else{''}}
}

function Initialize-TestV2AdaptationStore([string]$WorkspaceRoot,[object[]]$ProfileEntries=@()) {
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  $now = '2026-07-22T00:00:00Z'
  Write-TestAdaptationJson $paths.state ([pscustomobject]@{schema='super-brain.user-adaptation-state.v1';enabled=$true;updatedAt=$now;rawPromptStored=$false})
  Write-TestAdaptationJson $paths.observations ([pscustomobject]@{schema='super-brain.user-adaptation-observations.v1';updatedAt=$now;items=@();rawPromptStored=$false})
  Write-TestAdaptationJson $paths.candidates ([pscustomobject]@{schema='super-brain.user-adaptation-candidates.v1';updatedAt=$now;items=@();rawPromptStored=$false})
  Write-TestAdaptationJson $paths.profile ([pscustomobject]@{schema='super-brain.user-adaptation-profile.v1';updatedAt=$now;entries=@($ProfileEntries);profilePressure='ok';rawPromptStored=$false})
  Write-TestAdaptationJson $paths.tombstones ([pscustomobject]@{schema='super-brain.user-adaptation-tombstones.v1';updatedAt=$now;items=@();rawPromptStored=$false})
  $preview = Get-UserAdaptationMigrationPreview -Root $Root -WorkspaceRoot $WorkspaceRoot
  $preview.ok | Should Be $true
  return Invoke-UserAdaptationMigrationApply -Root $Root -ExpectedMigrationId $preview.migrationId -ExpectedRevision 0 -WorkspaceRoot $WorkspaceRoot -TransitionId ("test-migrate-" + (Get-UserAdaptationHash $WorkspaceRoot 8))
}

function Add-TestV2VerifiedObservation {
  param(
    [string]$WorkspaceRoot,[string]$HabitKey,[string]$Value,[string]$Scope,[string]$ScopeKey,[string]$Context,[string]$TaskId,[int]$ExpectedRevision,
    $Parameters=$null,[string]$EvidenceKind='verified_outcome',[string]$Producer='task_verification',[string]$EvidenceDate='',[string]$TransitionId='',[string]$Signal='Support'
  )
  $workspaceKey=if($Scope-eq'workflow'){($ScopeKey-split':',2)[0]}elseif($Scope-eq'project'){$ScopeKey}else{'ws-ffffffffffffffffffffffff'}
  $workflowKey=if($Scope-eq'workflow'){($ScopeKey-split':',2)[1]}else{''}
  $measurement=if($EvidenceKind-eq'workflow_measurement'){"review_protocol=multi_pass;forwardPasses=$([int]$Parameters.forwardPasses);reversePasses=$([int]$Parameters.reversePasses);riskFloor=$([string]$Parameters.riskFloor)"+$(if($Parameters.PSObject.Properties['contexts']){';contexts='+(@($Parameters.contexts|Sort-Object -Unique)-join',')}else{''})}else{''}
  $artifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -WorkspaceKey $workspaceKey -Signals $(if($measurement){@()}else{@("$HabitKey=$Value")}) -Measurements $(if($measurement){@($measurement)}else{@()}) -Context $Context -WorkflowKey $workflowKey
  return Add-UserAdaptationObservation -Root $Root -HabitKey $HabitKey -Value $Value -Signal $Signal -Source accepted_outcome -Scope $Scope -ScopeKey $ScopeKey -Context $Context -TaskId $TaskId -EvidenceRef ("verified|"+$TaskId) -WorkspaceRoot $WorkspaceRoot -Parameters $Parameters -EvidenceKind $EvidenceKind -Producer $Producer -EvidenceDate $EvidenceDate -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId -VerificationArtifactPath $artifact.path -VerificationHash $artifact.sha256
}

function Set-TestVerifiedOutcome {
  param([string]$WorkspaceRoot,[string]$TaskId,[string]$WorkspaceKey,[bool]$Ok=$true)
  Write-TestAdaptationJson (Join-Path $WorkspaceRoot 'last-task-verification.json') ([pscustomobject]@{
    ok=$Ok
    taskId=$TaskId
    workspaceKey=$WorkspaceKey
    checkedAt='2026-07-16 15:00:00'
  })
}

function Set-TestCanonicalVerifiedOutcome {
  param([string]$WorkspaceRoot,[string]$TaskId,[string]$WorkspaceKey,[string[]]$Signals=@('response_detail=concise'),[string[]]$Measurements=@(),[string]$Source='accepted_outcome',[string]$Context='coding',[string]$WorkflowKey='',[string]$CorrectionCandidateId='',[string]$CorrectionTargetPreferenceId='')
  return Write-TestAdaptationVerificationArtifact -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -WorkspaceKey $WorkspaceKey -Signals $Signals -Measurements $Measurements -Source $Source -Context $Context -WorkflowKey $WorkflowKey -CorrectionCandidateId $CorrectionCandidateId -CorrectionTargetPreferenceId $CorrectionTargetPreferenceId
}

function Invoke-TestAdaptationObserver {
  param(
    [string]$WorkspaceRoot,
    [string]$TaskId,
    [string]$WorkspaceKey,
    [string[]]$Signals,
    [string]$Mode='Apply',
    [string]$Context='coding',
    [string]$Source='accepted_outcome',
    [string]$WorkflowKey='',
    [string]$CorrectionCandidateId='',
    [string[]]$Measurements=@(),
    [string]$VerificationArtifactPath='',
    [string]$CorrectionTargetPreferenceId=''
  )
  $arguments = @{Mode=$Mode;TaskId=$TaskId;WorkspaceKey=$WorkspaceKey;Signals=$Signals;Measurements=$Measurements;Context=$Context;Source=$Source;WorkspaceRoot=$WorkspaceRoot;NoExit=$true;Json=$true}
  if (-not [string]::IsNullOrWhiteSpace($WorkflowKey)) { $arguments.WorkflowKey = $WorkflowKey }
  if (-not [string]::IsNullOrWhiteSpace($CorrectionCandidateId)) { $arguments.CorrectionCandidateId = $CorrectionCandidateId }
  if (-not [string]::IsNullOrWhiteSpace($VerificationArtifactPath)) { $arguments.VerificationArtifactPath = $VerificationArtifactPath }
  if (-not [string]::IsNullOrWhiteSpace($CorrectionTargetPreferenceId)) { $arguments.CorrectionTargetPreferenceId = $CorrectionTargetPreferenceId }
  return ((@(& $Observer @arguments) -join "`n") | ConvertFrom-Json)
}

function Invoke-TestVerifiedAdaptationObserver {
  param(
    [string]$WorkspaceRoot,[string]$TaskId,[string]$WorkspaceKey,[string[]]$Signals,[string]$Context='coding',[string]$Source='accepted_outcome',[string]$WorkflowKey='',[string[]]$Measurements=@(),[string]$CorrectionCandidateId='',[string]$CorrectionTargetPreferenceId='',[string]$EvidenceDate=''
  )
  $artifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -WorkspaceKey $WorkspaceKey -Signals $Signals -Measurements $Measurements -Source $Source -Context $Context -WorkflowKey $WorkflowKey -CorrectionCandidateId $CorrectionCandidateId -CorrectionTargetPreferenceId $CorrectionTargetPreferenceId -CheckedAt $EvidenceDate
  return Invoke-TestAdaptationObserver $WorkspaceRoot $TaskId $WorkspaceKey $Signals Apply $Context $Source $WorkflowKey $CorrectionCandidateId $Measurements $artifact.path $CorrectionTargetPreferenceId
}

function Invoke-TestHookProcess {
  param([string]$StateRoot,[string]$Prompt)
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = 'powershell.exe'
  $start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Hook`""
  $start.WorkingDirectory = $Root
  $start.UseShellExecute = $false
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.EnvironmentVariables['SUPER_BRAIN_STATE_ROOT'] = $StateRoot
  $process = [Diagnostics.Process]::Start($start)
  $process.StandardInput.Write((@{prompt=$Prompt} | ConvertTo-Json -Compress))
  $process.StandardInput.Close()
  $output = $process.StandardOutput.ReadToEnd()
  $errorText = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  return [pscustomobject]@{exitCode=$process.ExitCode;output=$output;error=$errorText}
}

Describe 'Governed user adaptation' {
  BeforeEach {
    $script:AdaptationWorkspace = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $script:AdaptationWorkspace | Out-Null
  }

  It 'validates the V2 policy contract and bounded personalization budget' {
    $contract = Assert-UserAdaptationPolicyV2 $Root
    $contract.ok | Should Be $true
    $contract.schemaVersion | Should Be 2
    $contract.packet.maxDirectives | Should Be 3
    $contract.packet.maxTokens | Should Be 96
    $contract.packet.maxChars | Should Be 384
    $contract.evidenceKindCount | Should Be 5
  }

  It 'validates typed review parameters without clamping or freeform fields' {
    $typed = ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey review_protocol -Value multi_pass -Parameters ([pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural'})
    $typed.valueKind | Should Be 'bounded_parameters'
    $typed.parameters.forwardPasses | Should Be 3
    $typed.parameters.reversePasses | Should Be 2
    $typed.parameters.riskFloor | Should Be 'structural'
    $scoped = ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey review_protocol -Value multi_pass -Parameters ([pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural';contexts=@('review','coding','review')})
    @($scoped.parameters.contexts) | Should Be @('coding','review')

    $errors = @()
    foreach ($parameters in @(
      [pscustomobject]@{forwardPasses=6;reversePasses=2;riskFloor='structural'},
      [pscustomobject]@{forwardPasses='3';reversePasses=2;riskFloor='structural'},
      [pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='cosmetic'},
      [pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural';contexts='review'},
      [pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural';contexts=@('unknown')},
      [pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural';contexts=@()},
      [pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural';notes='freeform'},
      [pscustomobject]@{forwardPasses=3;riskFloor='structural'}
    )) {
      try { $null = ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey review_protocol -Value multi_pass -Parameters $parameters; $errors += 'missing_error' }
      catch { $errors += $_.Exception.Message }
    }
    @($errors | Where-Object { $_ -eq 'missing_error' }).Count | Should Be 0
    ($errors -join '|') | Should Match 'USER_ADAPTATION_PARAMETER_'
    (Test-Path (Get-UserAdaptationPaths $Root $script:AdaptationWorkspace).directory) | Should Be $false
  }

  It 'counts review passes from independent completed plan items rather than label numbers' {
    $contract=[pscustomobject]@{
      canonicalPlan=[pscustomobject]@{orderConfidence='verified';approvalSource='user_confirmation';currentFingerprint='plan-count-fingerprint';items=@(
        [pscustomobject]@{itemId='forward-item';ordinal=1;status='completed';label='Forward review pass 5'},
        [pscustomobject]@{itemId='reverse-item';ordinal=2;status='completed';label='Reverse audit 3'},
        [pscustomobject]@{itemId='boundary-item';ordinal=3;status='completed';label='Structural boundary verification'}
      )}
      constraints=@('structural risk is the minimum boundary');acceptanceCriteria=@('all approved items complete')
    }
    $verified=Get-UserAdaptationVerifiedReviewProtocolMeasurement 'review_protocol=multi_pass;forwardPasses=1;reversePasses=1;riskFloor=structural' $contract
    $verified.ok | Should Be $true
    $verified.actualForward | Should Be 1
    $verified.actualReverse | Should Be 1
    $labelNumberClaim=Get-UserAdaptationVerifiedReviewProtocolMeasurement 'review_protocol=multi_pass;forwardPasses=5;reversePasses=3;riskFloor=structural' $contract
    $labelNumberClaim.ok | Should Be $false
    $labelNumberClaim.actualForward | Should Be 1
    $labelNumberClaim.actualReverse | Should Be 1
  }

  It 'previews a lossless four-preference V1 migration without mutating state' {
    $paths = Get-UserAdaptationPaths $Root $script:AdaptationWorkspace
    $now = '2026-07-22T00:00:00Z'
    Write-TestAdaptationJson $paths.state ([pscustomobject]@{schema='super-brain.user-adaptation-state.v1';enabled=$true;updatedAt=$now;rawPromptStored=$false})
    Write-TestAdaptationJson $paths.observations ([pscustomobject]@{schema='super-brain.user-adaptation-observations.v1';updatedAt=$now;items=@();rawPromptStored=$false})
    Write-TestAdaptationJson $paths.candidates ([pscustomobject]@{schema='super-brain.user-adaptation-candidates.v1';updatedAt=$now;items=@();rawPromptStored=$false})
    $entries = @(
      @('pref-detail','response_detail','balanced'),
      @('pref-reason','reasoning_style','evidence_first'),
      @('pref-proactive','proactivity','material_only'),
      @('pref-feature','feature_thinking','integrated')
    ) | ForEach-Object {
      [pscustomobject]@{preferenceId=$_[0];scope='global';scopeKey='global';habitKey=$_[1];value=$_[2];source='explicit_user';confidence=0.99;supportCount=1;distinctTaskCount=1;distinctContextCount=1;contradictionCount=0;contexts=@('general');status='active';updatedAt=$now;rawPromptStored=$false}
    }
    Write-TestAdaptationJson $paths.profile ([pscustomobject]@{schema='super-brain.user-adaptation-profile.v1';updatedAt=$now;entries=$entries;profilePressure='ok';rawPromptStored=$false})
    Write-TestAdaptationJson $paths.tombstones ([pscustomobject]@{schema='super-brain.user-adaptation-tombstones.v1';updatedAt=$now;items=@([pscustomobject]@{preferenceHash='legacy-hash';forgottenAt=$now});rawPromptStored=$false})
    $before = @($paths.state,$paths.observations,$paths.candidates,$paths.profile,$paths.tombstones | ForEach-Object { Get-SuperBrainFileSha256 $_ })

    $preview = Get-UserAdaptationMigrationPreview -Root $Root -WorkspaceRoot $script:AdaptationWorkspace

    $preview.ok | Should Be $true
    $preview.mutationPerformed | Should Be $false
    $preview.sourceFileCount | Should Be 5
    $preview.profileEntryCount | Should Be 4
    $preview.preservedProfileEntryCount | Should Be 4
    $preview.targetSchemas.profile | Should Be 'super-brain.user-adaptation-profile.v2'
    $preview.rollbackReceiptSchema | Should Be 'super-brain.user-adaptation-rollback-receipt.v2'
    @($preview.files | Where-Object { $_.pathStored -ne $false }).Count | Should Be 0
    @($paths.state,$paths.observations,$paths.candidates,$paths.profile,$paths.tombstones | ForEach-Object { Get-SuperBrainFileSha256 $_ }) | Should Be $before
    (Test-Path $paths.receipts) | Should Be $false
    (Test-Path $paths.hotProjection) | Should Be $false
    (Test-Path $paths.migration) | Should Be $false
  }

  It 'fails migration preview closed on malformed V1 state and preserves the source bytes' {
    $paths = Get-UserAdaptationPaths $Root $script:AdaptationWorkspace
    New-Item -ItemType Directory -Force -Path $paths.directory | Out-Null
    Write-Utf8NoBom $paths.profile '{"schema":"super-brain.user-adaptation-profile.v1","entries":['
    $before = Get-SuperBrainFileSha256 $paths.profile

    $preview = Get-UserAdaptationMigrationPreview -Root $Root -WorkspaceRoot $script:AdaptationWorkspace

    $preview.ok | Should Be $false
    $preview.applicable | Should Be $false
    ($preview.issues -join '|') | Should Match 'USER_ADAPTATION_MIGRATION_SOURCE_INVALID'
    (Get-SuperBrainFileSha256 $paths.profile) | Should Be $before
    (Test-Path $paths.migration) | Should Be $false
  }

  It 'applies migration backup-first, preserves V1 bytes, and replays idempotently' {
    $paths = Get-UserAdaptationPaths $Root $script:AdaptationWorkspace
    $entry = [pscustomobject]@{preferenceId='pref-existing';scope='global';scopeKey='global';habitKey='response_detail';value='balanced';source='explicit_user';confidence=0.99;supportCount=1;distinctTaskCount=1;distinctContextCount=1;contradictionCount=0;contexts=@('general');status='active';updatedAt='2026-07-22T00:00:00Z';rawPromptStored=$false}
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace @($entry)
    $sourceHashes = @($paths.state,$paths.observations,$paths.candidates,$paths.profile,$paths.tombstones | ForEach-Object { Get-SuperBrainFileSha256 $_ }) -join '|'
    $store = Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace
    $store.revision | Should Be 1
    @($store.profile).Count | Should Be 1
    @($store.profile)[0].preferenceId | Should Be 'pref-existing'
    $manifest = Get-ChildItem -LiteralPath $paths.migration -Filter manifest.json -Recurse | Select-Object -First 1
    $manifest | Should Not BeNullOrEmpty
    $backup = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    @($backup.entries).Count | Should Be 5
    @($backup.entries | Where-Object { $_.sha256 -ne $_.backupSha256 }).Count | Should Be 0
    (@($paths.state,$paths.observations,$paths.candidates,$paths.profile,$paths.tombstones | ForEach-Object { Get-SuperBrainFileSha256 $_ }) -join '|') | Should Be $sourceHashes

    $replay = Invoke-UserAdaptationMigrationApply -Root $Root -ExpectedMigrationId $store.migrationId -ExpectedRevision 0 -WorkspaceRoot $script:AdaptationWorkspace -TransitionId ("test-migrate-" + (Get-UserAdaptationHash $script:AdaptationWorkspace 8))
    $replay.replayed | Should Be $true
    (Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).revision | Should Be 1
  }

  It 'keeps V1 byte-identical and V2 inactive at every migration fault point' {
    foreach($fault in @('after_backup','before_publish','after_publish')){
      $workspace=Join-Path $TestDrive ("migration-fault-"+$fault);$paths=Get-UserAdaptationPaths $Root $workspace;$now='2026-07-22T00:00:00Z'
      Write-TestAdaptationJson $paths.state ([pscustomobject]@{schema='super-brain.user-adaptation-state.v1';enabled=$true;updatedAt=$now;rawPromptStored=$false})
      Write-TestAdaptationJson $paths.observations ([pscustomobject]@{schema='super-brain.user-adaptation-observations.v1';updatedAt=$now;items=@();rawPromptStored=$false})
      Write-TestAdaptationJson $paths.candidates ([pscustomobject]@{schema='super-brain.user-adaptation-candidates.v1';updatedAt=$now;items=@();rawPromptStored=$false})
      Write-TestAdaptationJson $paths.profile ([pscustomobject]@{schema='super-brain.user-adaptation-profile.v1';updatedAt=$now;entries=@();profilePressure='ok';rawPromptStored=$false})
      Write-TestAdaptationJson $paths.tombstones ([pscustomobject]@{schema='super-brain.user-adaptation-tombstones.v1';updatedAt=$now;items=@();rawPromptStored=$false})
      $sourcePaths=@($paths.state,$paths.observations,$paths.candidates,$paths.profile,$paths.tombstones);$before=@($sourcePaths|ForEach-Object{Get-SuperBrainFileSha256 $_})-join'|';$preview=Get-UserAdaptationMigrationPreview $Root $workspace;$failure=''
      try{$null=Invoke-UserAdaptationMigrationApply -Root $Root -ExpectedMigrationId $preview.migrationId -ExpectedRevision 0 -WorkspaceRoot $workspace -TransitionId ("fault-"+$fault) -FaultPoint $fault}catch{$failure=$_.Exception.Message}
      $failure | Should Match 'USER_ADAPTATION_FAULT_'
      (@($sourcePaths|ForEach-Object{Get-SuperBrainFileSha256 $_})-join'|') | Should Be $before
      (Test-Path $paths.storeV2) | Should Be $false
      @(Get-ChildItem -LiteralPath $paths.migration -Filter rollback-receipt.json -Recurse).Count | Should Be 1
    }
  }

  It 'rejects mixed V1 and V2 migration sources' {
    $paths=Get-UserAdaptationPaths $Root $script:AdaptationWorkspace
    Write-TestAdaptationJson $paths.state ([pscustomobject]@{schema='super-brain.user-adaptation-state.v1';enabled=$true;rawPromptStored=$false})
    Write-TestAdaptationJson $paths.profile ([pscustomobject]@{schema='super-brain.user-adaptation-profile.v2';revision=1;entries=@();rawPromptStored=$false})
    $preview=Get-UserAdaptationMigrationPreview $Root $script:AdaptationWorkspace
    $preview.ok | Should Be $false
    ($preview.issues -join '|') | Should Match 'mixed_or_already_v2:profile'
  }

  It 'enforces CAS and transition idempotency for V2 observations' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $first = Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-aaaaaaaaaaaaaaaaaaaaaaaa -Context coding -TaskId task-a -ExpectedRevision 1 -TransitionId observe-a
    $first.revision | Should Be 2
    $replay = Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-aaaaaaaaaaaaaaaaaaaaaaaa -Context coding -TaskId task-a -ExpectedRevision 1 -TransitionId observe-a
    $replay.replayed | Should Be $true
    $collision = ''
    try { $null = Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value detailed -Scope project -ScopeKey ws-aaaaaaaaaaaaaaaaaaaaaaaa -Context coding -TaskId task-a -ExpectedRevision 1 -TransitionId observe-a }
    catch { $collision = $_.Exception.Message }
    $collision | Should Match 'USER_ADAPTATION_TRANSITION_ID_CONFLICT'
    $casError = ''
    try { $null = Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-aaaaaaaaaaaaaaaaaaaaaaaa -Context debugging -TaskId task-b -ExpectedRevision 1 -TransitionId observe-b }
    catch { $casError = $_.Exception.Message }
    $casError | Should Match 'USER_ADAPTATION_REVISION_MISMATCH'
    (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).observationCount | Should Be 1
  }

  It 'allows exactly one of two concurrent writers at the same V2 revision' {
    $null=Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $escapedRoot=$Root.Replace("'","''");$escapedCore=$Core.Replace("'","''");$escapedWorkspace=$script:AdaptationWorkspace.Replace("'","''")
    $processes=@()
    foreach($suffix in @('a','b')){
      $verificationArtifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $script:AdaptationWorkspace -TaskId ("concurrent-"+$suffix) -WorkspaceKey 'ws-aaaaaaaaaaaaaaaaaaaaaaaa' -Signals @('response_detail=concise') -Context coding;$verificationPath=$verificationArtifact.path;$verificationHash=$verificationArtifact.sha256;$escapedVerification=$verificationPath.Replace("'","''")
      $command=". '$escapedRoot\scripts\common.ps1';. '$escapedCore';try{Add-UserAdaptationObservation -Root '$escapedRoot' -HabitKey response_detail -Value concise -Source accepted_outcome -Scope project -ScopeKey ws-aaaaaaaaaaaaaaaaaaaaaaaa -Context coding -TaskId concurrent-$suffix -EvidenceRef concurrent-$suffix -WorkspaceRoot '$escapedWorkspace' -ExpectedRevision 1 -TransitionId concurrent-$suffix -VerificationArtifactPath '$escapedVerification' -VerificationHash '$verificationHash'|ConvertTo-Json -Compress;exit 0}catch{[pscustomobject]@{error=`$_.Exception.Message}|ConvertTo-Json -Compress;exit 1}"
      $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='powershell.exe';$start.Arguments="-NoProfile -ExecutionPolicy Bypass -Command `"$($command.Replace('"','\"'))`"";$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$processes+=[Diagnostics.Process]::Start($start)
    }
    foreach($process in $processes){$process.WaitForExit()}
    @($processes|Where-Object{$_.ExitCode-eq0}).Count | Should Be 1
    @($processes|Where-Object{$_.ExitCode-ne0}).Count | Should Be 1
    $status=Get-UserAdaptationStatus $Root $script:AdaptationWorkspace;$status.revision | Should Be 2;$status.observationCount | Should Be 1
    (Test-Path ((Get-UserAdaptationPaths $Root $script:AdaptationWorkspace).coordination+'.lock')) | Should Be $false
  }

  It 'commits exactly one complete batch when two batches share one expected revision' {
    $null=Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $escapedRoot=$Root.Replace("'","''");$escapedCore=$Core.Replace("'","''");$escapedWorkspace=$script:AdaptationWorkspace.Replace("'","''")
    $processes=@()
    foreach($suffix in @('a','b')){
      $taskId="concurrent-batch-$suffix"
      $artifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $script:AdaptationWorkspace -TaskId $taskId -WorkspaceKey 'ws-adadadadadadadadadadadad' -Signals @('response_detail=concise') -Context coding
      $escapedVerification=$artifact.path.Replace("'","''")
      $command=". '$escapedRoot\scripts\common.ps1';. '$escapedCore';try{Add-UserAdaptationObservationBatchV2 -Root '$escapedRoot' -Items @([pscustomobject]@{habitKey='response_detail';value='concise'}) -Source accepted_outcome -Scope project -ScopeKey ws-adadadadadadadadadadadad -Context coding -TaskId '$taskId' -WorkspaceRoot '$escapedWorkspace' -ExpectedRevision 1 -TransitionId batch-$suffix -VerificationArtifactPath '$escapedVerification' -VerificationHash '$($artifact.sha256)'|ConvertTo-Json -Compress;exit 0}catch{[pscustomobject]@{error=`$_.Exception.Message}|ConvertTo-Json -Compress;exit 1}"
      $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='powershell.exe';$start.Arguments="-NoProfile -ExecutionPolicy Bypass -Command `"$($command.Replace('"','\"'))`"";$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$processes+=[Diagnostics.Process]::Start($start)
    }
    foreach($process in $processes){$process.WaitForExit()}
    @($processes|Where-Object{$_.ExitCode-eq0}).Count | Should Be 1
    @($processes|Where-Object{$_.ExitCode-ne0}).Count | Should Be 1
    $store=Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace
    [int]$store.revision | Should Be 2
    @($store.observations).Count | Should Be 1
    @($store.receipts|Where-Object{$_.kind-eq'observation_batch'}).Count | Should Be 1
    $paths=Get-UserAdaptationPaths $Root $script:AdaptationWorkspace
    (Test-Path ($paths.coordination+'.lock')) | Should Be $false
    (Test-Path ($paths.storeV2+'.lock')) | Should Be $false
  }

  It 'publishes one immutable evidence snapshot under concurrent replay and detects later tampering' {
    $source=Join-Path $script:AdaptationWorkspace 'verified-outcome-source.json'
    $destinationRoot=Join-Path $script:AdaptationWorkspace 'runtime-state\user-adaptation-outcomes'
    $destination=Join-Path $destinationRoot 'task-concurrent--content-hash.json'
    Write-TestAdaptationJson $source ([pscustomobject]@{schema='test.immutable-outcome.v1';taskId='task-concurrent';rawPromptStored=$false})
    $expected=Get-SuperBrainFileSha256 $source
    $escapedCommon=(Join-Path $Root 'scripts\common.ps1').Replace("'","''")
    $escapedSource=$source.Replace("'","''");$escapedDestination=$destination.Replace("'","''")
    $processes=@()
    foreach($index in 1..4){
      $command=". '$escapedCommon';try{Publish-SuperBrainImmutableFile -SourcePath '$escapedSource' -DestinationPath '$escapedDestination' -ExpectedSha256 '$expected' -CollisionCode USER_ADAPTATION_OUTCOME_SNAPSHOT_COLLISION -SourceMismatchCode USER_ADAPTATION_VERIFIED_OUTCOME_MISMATCH|ConvertTo-Json -Compress;exit 0}catch{[pscustomobject]@{error=`$_.Exception.Message}|ConvertTo-Json -Compress;exit 1}"
      $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='powershell.exe';$start.Arguments="-NoProfile -ExecutionPolicy Bypass -Command `"$($command.Replace('"','\"'))`"";$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$processes+=[Diagnostics.Process]::Start($start)
    }
    $results=@()
    foreach($process in $processes){$output=$process.StandardOutput.ReadToEnd();$errorOutput=$process.StandardError.ReadToEnd();$process.WaitForExit();$process.ExitCode|Should Be 0;$errorOutput|Should BeNullOrEmpty;$results+=(($output.Trim())|ConvertFrom-Json)}
    @($results|Where-Object{$_.published-eq$true}).Count|Should Be 1
    @($results|Where-Object{$_.replayed-eq$true}).Count|Should Be 3
    (Get-SuperBrainFileSha256 $destination)|Should Be $expected
    @(Get-ChildItem -LiteralPath $destinationRoot -File -Filter '.pending-*' -ErrorAction SilentlyContinue).Count|Should Be 0
    (Test-Path -LiteralPath ($destination+'.lock'))|Should Be $false

    Write-TestAdaptationJson $destination ([pscustomobject]@{schema='tampered'})
    $collision=''
    try{$null=Publish-SuperBrainImmutableFile -SourcePath $source -DestinationPath $destination -ExpectedSha256 $expected -CollisionCode USER_ADAPTATION_OUTCOME_SNAPSHOT_COLLISION -SourceMismatchCode USER_ADAPTATION_VERIFIED_OUTCOME_MISMATCH}catch{$collision=$_.Exception.Message}
    $collision|Should Match '^USER_ADAPTATION_OUTCOME_SNAPSHOT_COLLISION'
  }

  It 'stages then activates a scoped typed review protocol but withholds a global inferred one' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $revision = 1
    $samples = @(
      @('review-1','coding','2026-07-20',3,2),
      @('review-2','review','2026-07-20',3,2),
      @('review-3','coding','2026-07-21',3,2),
      @('review-4','review','2026-07-21',4,2)
    )
    foreach($sample in $samples){$result=Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey review_protocol -Value multi_pass -Scope workflow -ScopeKey 'ws-aaaaaaaaaaaaaaaaaaaaaaaa:code-review' -Context $sample[1] -TaskId $sample[0] -Parameters ([pscustomobject]@{forwardPasses=[int]$sample[3];reversePasses=[int]$sample[4];riskFloor='structural'}) -EvidenceKind workflow_measurement -Producer verified_task_protocol -EvidenceDate $sample[2] -ExpectedRevision $revision -TransitionId ("observe-"+$sample[0]);$revision=$result.revision}
    $staged = Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $revision -TransitionId review-stage
    $staged.stagedPreferenceCount | Should Be 1
    $staged.activePreferenceCount | Should Be 0
    $stagedCandidate=@((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).candidates)[0]
    $stagedCandidate.supportCount|Should Be 4
    $stagedCandidate.modeSupportCount|Should Be 3
    $stagedCandidate.modeShare|Should Be 0.75
    $stagedCandidate.contradictionCount|Should Be 0
    $stagedCandidate.parameters.forwardPasses|Should Be 3
    $stagedCandidate.validation.status | Should Be 'validated'
    $stagedCandidate.validation.scopedEvidence | Should Be $true
    $stagedCandidate.validation.overfitGuardPassed | Should Be $true
    $staged.validatedCandidateCount | Should Be 1
    $revision = $staged.revision
    $fifth = Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey review_protocol -Value multi_pass -Scope workflow -ScopeKey 'ws-aaaaaaaaaaaaaaaaaaaaaaaa:code-review' -Context coding -TaskId review-5 -Parameters ([pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural'}) -EvidenceKind workflow_measurement -Producer verified_task_protocol -EvidenceDate '2026-07-22' -ExpectedRevision $revision -TransitionId observe-review-5
    $active = Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $fifth.revision -TransitionId review-activate
    $active.activePreferenceCount | Should Be 1
    $packet = Get-UserAdaptationPacket -Root $Root -Context review -WorkspaceKey ws-aaaaaaaaaaaaaaaaaaaaaaaa -WorkflowKey code-review -WorkspaceRoot $script:AdaptationWorkspace
    $packet.applies | Should Be $true
    ($packet.directives -join '|') | Should Match '3 forward review pass'
    ($packet.directives -join '|') | Should Match '2 reverse-audit pass'

    $globalError=''
    try{$null=Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey review_protocol -Value multi_pass -Scope global -ScopeKey '' -Context review -TaskId global-review -Parameters ([pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural'}) -EvidenceKind workflow_measurement -Producer verified_task_protocol -EvidenceDate '2026-07-22' -ExpectedRevision $active.revision}catch{$globalError=$_.Exception.Message}
    $globalError | Should Match 'USER_ADAPTATION_VERIFICATION_ARTIFACT_INVALID'
  }

  It 'withholds unstable numeric review habits without misclassifying normal variation as contradiction' {
    $null=Initialize-TestV2AdaptationStore $script:AdaptationWorkspace;$revision=1
    $samples=@(@('unstable-1','coding','2026-07-20',1),@('unstable-2','review','2026-07-20',1),@('unstable-3','coding','2026-07-21',5),@('unstable-4','review','2026-07-21',5))
    foreach($sample in $samples){$observed=Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey review_protocol -Value multi_pass -Scope workflow -ScopeKey 'ws-abababababababababababab:code-review' -Context $sample[1] -TaskId $sample[0] -Parameters ([pscustomobject]@{forwardPasses=[int]$sample[3];reversePasses=1;riskFloor='structural'}) -EvidenceKind workflow_measurement -Producer verified_task_protocol -EvidenceDate $sample[2] -ExpectedRevision $revision;$revision=$observed.revision}
    $result=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $revision
    $candidate=@((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).candidates)[0]
    $result.activePreferenceCount|Should Be 0
    $result.stagedPreferenceCount|Should Be 0
    $candidate.status|Should Be 'candidate'
    $candidate.modeShare|Should Be 0.5
    $candidate.medianAbsoluteDeviation|Should Be 2
    $candidate.contradictionCount|Should Be 0
    $candidate.validation.status | Should Be 'pending'
    $candidate.validation.overfitGuardPassed | Should Be $false
  }

  It 'treats risk floor and applicability contexts as semantic conflicts' {
    foreach($variant in @('risk','contexts')){
      $workspace=Join-Path $TestDrive ('semantic-conflict-'+$variant);$null=Initialize-TestV2AdaptationStore $workspace;$revision=1
      foreach($index in 1..4){
        $parameters=if($variant-eq'risk'){
          [pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor=if($index-le2){'structural'}else{'workflow'}}
        }else{
          $parameterContext=if($index-le2){'review'}else{'coding'}
          [pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural';contexts=[string[]]@($parameterContext)}
        }
        $observed=Add-TestV2VerifiedObservation -WorkspaceRoot $workspace -HabitKey review_protocol -Value multi_pass -Scope workflow -ScopeKey 'ws-cdcdcdcdcdcdcdcdcdcdcdcd:code-review' -Context $(if($index%2){'coding'}else{'review'}) -TaskId ("$variant-$index") -Parameters $parameters -EvidenceKind workflow_measurement -Producer verified_task_protocol -EvidenceDate $(if($index-le2){'2026-07-20'}else{'2026-07-21'}) -ExpectedRevision $revision;$revision=$observed.revision
      }
      $result=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $workspace -ExpectedRevision $revision
      $result.activePreferenceCount|Should Be 0
      $result.stagedPreferenceCount|Should Be 0
      $candidates=@((Get-UserAdaptationV2Store $Root $workspace).candidates)
      $candidates.Count|Should Be 2
      @($candidates|Where-Object{$_.status-eq'conflicted'}).Count|Should Be 2
      @($candidates|Where-Object{$_.contradictionCount-eq0}).Count|Should Be 0
    }
  }

  It 'suppresses inferred behavior on one verified correction and decays stale inference to dormant' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $revision=1
    foreach($sample in @(@('infer-1','coding'),@('infer-2','debugging'),@('infer-3','coding'))){$result=Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-bbbbbbbbbbbbbbbbbbbbbbbb -Context $sample[1] -TaskId $sample[0] -EvidenceDate '2026-07-20' -ExpectedRevision $revision;$revision=$result.revision}
    $stage=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $revision -Now ([datetime]'2026-07-22')
    $stage.activePreferenceCount | Should Be 0
    $stage.stagedPreferenceCount | Should Be 0
    @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).candidates)[0].distinctDateCount | Should Be 1
    $fourth=Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-bbbbbbbbbbbbbbbbbbbbbbbb -Context debugging -TaskId infer-4 -EvidenceDate '2026-07-21' -ExpectedRevision $stage.revision
    $secondStage=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $fourth.revision -Now ([datetime]'2026-07-22')
    $secondStage.stagedPreferenceCount | Should Be 1
    $fifth=Add-TestV2VerifiedObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-bbbbbbbbbbbbbbbbbbbbbbbb -Context coding -TaskId infer-5 -EvidenceDate '2026-07-21' -ExpectedRevision $secondStage.revision
    $active=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $fifth.revision -Now ([datetime]'2026-07-22')
    $active.activePreferenceCount | Should Be 1
    $activeStore=Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace;$targetPreferenceId=@($activeStore.profile|Where-Object{$_.status-eq'active'})[0].preferenceId
    $paths=Get-UserAdaptationPaths $Root $script:AdaptationWorkspace;$candidateId='correction-v2-closed';$candidatePath=Join-Path $paths.workspace "reflection\correction-candidates\$candidateId.json"
    $missingEvidence=''
    try{$null=Add-UserAdaptationObservation -Root $Root -HabitKey response_detail -Value detailed -Source user_correction -Scope project -ScopeKey ws-bbbbbbbbbbbbbbbbbbbbbbbb -Context coding -TaskId correction-1 -EvidenceRef correction-missing -WorkspaceRoot $script:AdaptationWorkspace -EvidenceKind verified_correction -Producer closed_correction -EvidenceDate '2026-01-03' -ExpectedRevision $active.revision}catch{$missingEvidence=$_.Exception.Message}
    $missingEvidence | Should Match 'USER_ADAPTATION_(?:CORRECTION_EVIDENCE|VERIFICATION_ARTIFACT)_REQUIRED'
    $verificationArtifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $script:AdaptationWorkspace -TaskId correction-1 -WorkspaceKey ws-bbbbbbbbbbbbbbbbbbbbbbbb -Signals @('response_detail=detailed') -Source user_correction -Context coding -CorrectionCandidateId $candidateId -CorrectionTargetPreferenceId $targetPreferenceId
    Write-TestAdaptationJson $candidatePath ([pscustomobject]@{schema='super-brain.correction-candidate.v1';candidateId=$candidateId;workspaceKey='ws-bbbbbbbbbbbbbbbbbbbbbbbb';status='closed';closedAt='2026-07-22T00:00:00Z';closureReason='verified_fix_outcome';analysisSummaryHash=('a'*24);promotionCandidateIds=@('promotion-1');durablePromotionAllowed=$true;rawPromptStored=$false;autonomyEvidenceLink=[pscustomobject]@{eligible=$true;taskId='correction-1';verifiedOutcomeRecordId='verified-task-correction-1';verifiedOutcomeSha256=$verificationArtifact.outcomeSha256;rawPromptStored=$false}})
    $correction=Add-UserAdaptationObservation -Root $Root -HabitKey response_detail -Value detailed -Source user_correction -Scope project -ScopeKey ws-bbbbbbbbbbbbbbbbbbbbbbbb -Context coding -TaskId correction-1 -EvidenceRef correction-1 -WorkspaceRoot $script:AdaptationWorkspace -EvidenceKind verified_correction -Producer closed_correction -EvidenceDate '2026-07-22' -ExpectedRevision $active.revision -CorrectionCandidateId $candidateId -CorrectionCandidateHash (Get-SuperBrainFileSha256 $candidatePath) -VerificationArtifactPath $verificationArtifact.path -VerificationHash $verificationArtifact.sha256 -CorrectionTargetPreferenceId $targetPreferenceId
    $correction.suppressedPreferenceId | Should Be $targetPreferenceId
    @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile|Where-Object{$_.preferenceId-eq$targetPreferenceId})[0].status | Should Be 'dormant'
    $suppressed=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $correction.revision -Now ([datetime]'2026-07-22')
    $suppressed.activePreferenceCount | Should Be 0
    $suppressed.dormantPreferenceCount | Should Be 1

    $decayWorkspace=Join-Path $TestDrive 'adaptation-decay'
    $null=Initialize-TestV2AdaptationStore $decayWorkspace;$revision=1
    foreach($sample in @(@('decay-1','coding'),@('decay-2','debugging'),@('decay-3','coding'))){$result=Add-TestV2VerifiedObservation -WorkspaceRoot $decayWorkspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-cccccccccccccccccccccccc -Context $sample[1] -TaskId $sample[0] -EvidenceDate '2026-07-20' -ExpectedRevision $revision;$revision=$result.revision}
    $stage=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $decayWorkspace -ExpectedRevision $revision -Now ([datetime]'2026-07-22');$fourth=Add-TestV2VerifiedObservation -WorkspaceRoot $decayWorkspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-cccccccccccccccccccccccc -Context debugging -TaskId decay-4 -EvidenceDate '2026-07-21' -ExpectedRevision $stage.revision;$secondStage=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $decayWorkspace -ExpectedRevision $fourth.revision -Now ([datetime]'2026-07-22');$fifth=Add-TestV2VerifiedObservation -WorkspaceRoot $decayWorkspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-cccccccccccccccccccccccc -Context coding -TaskId decay-5 -EvidenceDate '2026-07-21' -ExpectedRevision $secondStage.revision;$active=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $decayWorkspace -ExpectedRevision $fifth.revision -Now ([datetime]'2026-07-22')
    $decayed=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $decayWorkspace -ExpectedRevision $active.revision -Now ([datetime]'2027-03-01')
    $decayed.activePreferenceCount | Should Be 0
    $decayed.dormantPreferenceCount | Should Be 1
  }

  It 'computes inferred decay from base confidence idempotently at the same time' {
    $workspace=Join-Path $TestDrive 'decay-idempotent';$null=Initialize-TestV2AdaptationStore $workspace;$revision=1
    foreach($sample in @(@('idem-1','coding'),@('idem-2','debugging'),@('idem-3','coding'))){$result=Add-TestV2VerifiedObservation -WorkspaceRoot $workspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-dddddddddddddddddddddddd -Context $sample[1] -TaskId $sample[0] -EvidenceDate '2026-07-20' -ExpectedRevision $revision;$revision=$result.revision}
    $stage=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $workspace -ExpectedRevision $revision -Now ([datetime]'2026-07-22');$fourth=Add-TestV2VerifiedObservation -WorkspaceRoot $workspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-dddddddddddddddddddddddd -Context debugging -TaskId idem-4 -EvidenceDate '2026-07-21' -ExpectedRevision $stage.revision;$secondStage=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $workspace -ExpectedRevision $fourth.revision -Now ([datetime]'2026-07-22');$fifth=Add-TestV2VerifiedObservation -WorkspaceRoot $workspace -HabitKey response_detail -Value concise -Scope project -ScopeKey ws-dddddddddddddddddddddddd -Context coding -TaskId idem-5 -EvidenceDate '2026-07-21' -ExpectedRevision $secondStage.revision;$active=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $workspace -ExpectedRevision $fifth.revision -Now ([datetime]'2026-07-22')
    $first=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $workspace -ExpectedRevision $active.revision -Now ([datetime]'2026-10-22');$firstConfidence=[double]@((Get-UserAdaptationV2Store $Root $workspace).profile|Where-Object{$_.status-eq'active'})[0].confidence
    $second=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $workspace -ExpectedRevision $first.revision -Now ([datetime]'2026-10-22');$secondConfidence=[double]@((Get-UserAdaptationV2Store $Root $workspace).profile|Where-Object{$_.status-eq'active'})[0].confidence
    $secondConfidence | Should Be $firstConfidence
  }

  It 'prevents forgotten preference resurrection until explicit generation advance' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $observed=Add-UserAdaptationObservation -Root $Root -HabitKey speaking_style -Value warm_direct -Source explicit_user -Scope global -ScopeKey '' -Context general -TaskId explicit-style -EvidenceRef explicit-style -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision 1
    $active=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $observed.revision
    $preferenceId=@((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile|Where-Object{$_.status-eq'active'})[0].preferenceId
    $forgot=Remove-UserAdaptationPreference -Root $Root -PreferenceId $preferenceId -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $active.revision -TransitionId forget-style -Confirmed
    $blocked=''
    try{$null=Add-UserAdaptationObservation -Root $Root -HabitKey speaking_style -Value warm_direct -Source explicit_user -Scope global -ScopeKey '' -Context general -TaskId explicit-style-again -EvidenceRef explicit-style-again -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $forgot.revision}catch{$blocked=$_.Exception.Message}
    $blocked | Should Match 'USER_ADAPTATION_REINSTATE_REQUIRED'
    $reinstate=Invoke-UserAdaptationReinstateV2 -Root $Root -Scope global -ScopeKey '' -HabitKey speaking_style -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $forgot.revision -TransitionId reinstate-style -Confirmed
    $reinstate.identityGeneration | Should Be 2
    $evolutionAfterReinstate=Get-UserAdaptationEvolutionV2 -Root $Root -WorkspaceRoot $script:AdaptationWorkspace
    $evolutionAfterReinstate.retainedChangeCounts.reinstated | Should Be 1
    $repeatError=''
    try{$null=Invoke-UserAdaptationReinstateV2 -Root $Root -Scope global -ScopeKey '' -HabitKey speaking_style -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $reinstate.revision -TransitionId reinstate-style-again -Confirmed}catch{$repeatError=$_.Exception.Message}
    $repeatError | Should Match 'USER_ADAPTATION_REINSTATE_NOT_BLOCKED'
    $again=Add-UserAdaptationObservation -Root $Root -HabitKey speaking_style -Value warm_direct -Source explicit_user -Scope global -ScopeKey '' -Context general -TaskId explicit-style-again -EvidenceRef explicit-style-again -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $reinstate.revision
    $reactivated=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $again.revision
    $reactivated.activePreferenceCount | Should Be 1
    @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile)[0].identityGeneration | Should Be 2
  }

  It 'preserves all legacy tombstones and blocks a matching migrated preference' {
    $paths=Get-UserAdaptationPaths $Root $script:AdaptationWorkspace;$now='2026-07-22T00:00:00Z';$identity='global|global|response_detail|concise';$preferenceId='pref-'+(Get-UserAdaptationHash $identity 8)
    $entry=[pscustomobject]@{preferenceId=$preferenceId;scope='global';scopeKey='global';habitKey='response_detail';value='concise';source='explicit_user';confidence=0.99;supportCount=1;distinctTaskCount=1;distinctContextCount=1;contradictionCount=0;contexts=@('general');status='active';updatedAt=$now;rawPromptStored=$false}
    Write-TestAdaptationJson $paths.state ([pscustomobject]@{schema='super-brain.user-adaptation-state.v1';enabled=$true;updatedAt=$now;rawPromptStored=$false});Write-TestAdaptationJson $paths.observations ([pscustomobject]@{schema='super-brain.user-adaptation-observations.v1';updatedAt=$now;items=@();rawPromptStored=$false});Write-TestAdaptationJson $paths.candidates ([pscustomobject]@{schema='super-brain.user-adaptation-candidates.v1';updatedAt=$now;items=@();rawPromptStored=$false});Write-TestAdaptationJson $paths.profile ([pscustomobject]@{schema='super-brain.user-adaptation-profile.v1';updatedAt=$now;entries=@($entry);profilePressure='ok';rawPromptStored=$false})
    $legacy=@(1..65|ForEach-Object{[pscustomobject]@{preferenceHash=if($_-eq1){Get-UserAdaptationHash $preferenceId}else{Get-UserAdaptationHash ("pref-old-"+$_)};forgottenAt=$now}});Write-TestAdaptationJson $paths.tombstones ([pscustomobject]@{schema='super-brain.user-adaptation-tombstones.v1';updatedAt=$now;items=$legacy;rawPromptStored=$false})
    $preview=Get-UserAdaptationMigrationPreview $Root $script:AdaptationWorkspace;$null=Invoke-UserAdaptationMigrationApply -Root $Root -ExpectedMigrationId $preview.migrationId -ExpectedRevision 0 -WorkspaceRoot $script:AdaptationWorkspace -TransitionId legacy-migrate
    $status=Get-UserAdaptationStatus $Root $script:AdaptationWorkspace;$status.legacyTombstoneCount | Should Be 65
    (Get-UserAdaptationPacket -Root $Root -Context general -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
  }

  It 'stages verified inference after three tasks and activates only after further support' {
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-1 coding
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-2 coding
    (Invoke-TestAdaptationSynthesis $script:AdaptationWorkspace).activePreferenceCount | Should Be 0

    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-3 debugging
    $staged = Invoke-TestAdaptationSynthesis $script:AdaptationWorkspace
    $staged.activePreferenceCount | Should Be 0
    $staged.stagedPreferenceCount | Should Be 1
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-4 debugging
    $result = Invoke-TestAdaptationSynthesis $script:AdaptationWorkspace
    $result.activePreferenceCount | Should Be 1
    $profile = @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile)
    $profile[0].source | Should Be 'inferred'
    [double]$profile[0].confidence -ge 0.78 | Should Be $true
  }

  It 'promotes an explicit preference immediately' {
    $result = Set-TestAdaptationPreference $script:AdaptationWorkspace reasoning_style evidence_first
    $result.activePreferenceCount | Should Be 1
    $result.promotedPreferenceIds.Count | Should Be 1
    $profile = @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile)
    [double]$profile[0].confidence | Should Be 0.99
  }

  It 'lets a newer explicit turn replace and later reactivate a scoped value' {
    $null=Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey='ws-dededededededededededede'
    $revision=1
    foreach($sample in @(@('explicit-1','concise'),@('explicit-2','detailed'),@('explicit-3','concise'))){
      $observed=Add-UserAdaptationObservation -Root $Root -HabitKey response_detail -Value $sample[1] -Signal Support -Source explicit_user -Scope project -ScopeKey $workspaceKey -Context coding -TaskId $sample[0] -EvidenceRef $sample[0] -WorkspaceRoot $script:AdaptationWorkspace -EvidenceKind durable_explicit -Producer trusted_direct_statement -ExpectedRevision $revision -TransitionId ("observe-"+$sample[0])
      $synthesized=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int]$observed.revision) -TransitionId ("synthesize-"+$sample[0])
      $revision=[int]$synthesized.revision
      $active=@((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile|Where-Object{$_.habitKey-eq'response_detail'-and$_.status-eq'active'})
      $active.Count | Should Be 1
      $active[0].value | Should Be $sample[1]
    }
    $store=Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace
    @($store.profile|Where-Object{$_.habitKey-eq'response_detail'-and$_.status-eq'superseded'}).Count | Should Be 1
  }

  It 'applies workflow over project over global and isolates projects' {
    $projectKey='ws-aaaaaaaaaaaaaaaaaaaaaaaa'
    $foreignKey='ws-bbbbbbbbbbbbbbbbbbbbbbbb'
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace response_detail concise global '' general global-pref
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace response_detail detailed project $projectKey coding project-pref
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace response_detail balanced workflow "$projectKey`:code-review" review workflow-pref

    $workflow = Get-UserAdaptationPacket -Root $Root -Context review -WorkspaceKey $projectKey -WorkflowKey code-review -WorkspaceRoot $script:AdaptationWorkspace
    $workflow.preferences[0].scope | Should Be 'workflow'
    $workflow.preferences[0].value | Should Be 'balanced'

    $project = Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceKey $projectKey -WorkflowKey other -WorkspaceRoot $script:AdaptationWorkspace
    $project.preferences[0].scope | Should Be 'project'
    $project.preferences[0].value | Should Be 'detailed'

    $foreign = Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceKey $foreignKey -WorkflowKey other -WorkspaceRoot $script:AdaptationWorkspace
    $foreign.preferences[0].scope | Should Be 'global'
    $foreign.preferences[0].value | Should Be 'concise'
  }

  It 'applies problem-complete verification only to problem-review contexts' {
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace verification_depth problem_complete
    $coding = Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceRoot $script:AdaptationWorkspace
    $debugging = Get-UserAdaptationPacket -Root $Root -Context debugging -WorkspaceRoot $script:AdaptationWorkspace
    $review = Get-UserAdaptationPacket -Root $Root -Context review -WorkspaceRoot $script:AdaptationWorkspace
    $coding.applies | Should Be $false
    $debugging.preferences[0].value | Should Be 'problem_complete'
    $review.preferences[0].value | Should Be 'problem_complete'
  }

  It 'keeps low-confidence and contradicted signals silent' {
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-1 coding
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-2 debugging
    $low = Invoke-TestAdaptationSynthesis $script:AdaptationWorkspace
    $low.activePreferenceCount | Should Be 0

    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-3 coding
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail detailed task-4 general
    $conflicted = Invoke-TestAdaptationSynthesis $script:AdaptationWorkspace
    $conflicted.activePreferenceCount | Should Be 0
    (Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
  }

  It 'supports disable, enable, confirmed forget, and tombstone blocking' {
    $set = Set-TestAdaptationPreference $script:AdaptationWorkspace proactivity material_only
    $preferenceId = [string]$set.promotedPreferenceIds[0]
    $disabled=Set-UserAdaptationEnabled -Root $Root -Enabled $false -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int]$set.revision) -TransitionId lifecycle-disable
    $disabled.enabled | Should Be $false
    (Get-UserAdaptationPacket -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
    $enabled=Set-UserAdaptationEnabled -Root $Root -Enabled $true -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int]$disabled.revision) -TransitionId lifecycle-enable
    $enabled.enabled | Should Be $true
    (Get-UserAdaptationPacket -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $true

    $forgotten=Remove-UserAdaptationPreference -Root $Root -PreferenceId $preferenceId -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int]$enabled.revision) -TransitionId lifecycle-forget -Confirmed
    $forgotten.found | Should Be $true
    $blocked='';try{$null=Add-TestAdaptationObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey proactivity -Value material_only -TaskId explicit-again -Source explicit_user -EvidenceRef explicit-again}catch{$blocked=$_.Exception.Message}
    $blocked | Should Match 'USER_ADAPTATION_REINSTATE_REQUIRED'
    (Get-UserAdaptationPacket -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
  }

  It 'enforces observation and packet budgets' {
    for ($i = 1; $i -le 205; $i++) {
      $null = Add-TestAdaptationObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -TaskId "task-$i" -Context coding -EvidenceRef "budget-$i"
    }
    (Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).observationCount | Should Be 200

    $packetWorkspace = Join-Path $TestDrive 'packet-budget'
    $preferences = @(
      @('response_detail','balanced'),
      @('reasoning_style','evidence_first'),
      @('proactivity','material_only'),
      @('small_change_autonomy','auto'),
      @('structural_change_autonomy','discuss'),
      @('verification_depth','risk_based'),
      @('feature_thinking','integrated'),
      @('clarification_style','infer_then_confirm')
    )
    foreach ($preference in $preferences) { $null = Set-TestAdaptationPreference $packetWorkspace $preference[0] $preference[1] global '' general ("explicit-" + $preference[0]) }
    $packet = Get-UserAdaptationPacket -Root $Root -Context general -WorkspaceRoot $packetWorkspace
    $packet.directiveCount -le 3 | Should Be $true
    $packet.tokenEstimate -le 96 | Should Be $true
    (($packet.directives -join '').Length) -le 384 | Should Be $true
  }

  It 'stores no raw evidence or prompt sentinel' {
    $sentinel = 'RAW-PROMPT-SENTINEL-DO-NOT-STORE-7f42'
    $null = Add-TestAdaptationObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -TaskId safe-task -Source explicit_user -EvidenceRef $sentinel
    $null = Invoke-TestAdaptationSynthesis $script:AdaptationWorkspace
    $text = @(Get-ChildItem -LiteralPath (Get-UserAdaptationPaths $Root $script:AdaptationWorkspace).directory -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    $text.Contains($sentinel) | Should Be $false
    ($text.Contains('"rawPromptStored":  false') -or $text.Contains('"rawPromptStored":false')) | Should Be $true
  }

  # Retired P7 fixture retained as historical reference; H7 turn-runtime and
  # direct adaptation APIs are the current acceptance paths.
  It 'reports strong hook signals in test mode without mutating adaptation state' -Skip {
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $stateRoot = Join-Path $TestDrive 'hook-test-mode'
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $result = (& $Hook -TestPrompt 'Going forward, I prefer concise answers by default.' | ConvertFrom-Json)
      $result.hookSpecificOutput.additionalContext.Contains('USER_ADAPTATION_SIGNAL') | Should Be $true
      (Test-Path (Join-Path $stateRoot 'workspace\user-adaptation')) | Should Be $false
      $workspace = Join-Path $stateRoot 'workspace'
      $pointer = Get-Content -LiteralPath (Join-Path $workspace 'last-codex-user-prompt-hook.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $pointer.schema | Should Be 'super-brain.codex-user-prompt-hook-pointer.v1'
      $hookState = Get-Content -LiteralPath (Join-Path $workspace (([string]$pointer.telemetryRelativePath) -replace '/','\')) -Raw -Encoding UTF8 | ConvertFrom-Json
      $hookState.adaptationCapture.mode | Should Be 'test'
      $hookState.adaptationCapture.mutated | Should Be $false
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }

  # Retired P7 fixture retained as historical reference; H7 turn-runtime and
  # direct adaptation APIs are the current acceptance paths.
  It 'does not persist durable preferences from quotes examples code logs translations hypotheses or negation' -Skip {
    $stateRoot = Join-Path $TestDrive 'hook-negative-capture'
    $prompts = @(
      'For example, say "Going forward, I prefer concise answers by default."',
      (@('```text','Going forward, I prefer concise answers by default.','```') -join "`n"),
      'log: Going forward, I prefer concise answers by default.',
      '[INFO] Going forward, I prefer concise answers by default.',
      '> Going forward, I prefer concise answers by default.',
      'Translate: "Going forward, I prefer concise answers by default."',
      'If I say going forward I prefer concise answers, explain the sentence.',
      'Going forward, do not remember or learn that I prefer concise answers; it is not my preference.',
      'Going forward, I do not want concise answers.',
      'Going forward, do not be concise.',
      'Going forward, I no longer prefer detailed answers.',
      'Always use concise variable names in this file.',
      'Set concise as the default formatter option.',
      "'Going forward, I prefer concise answers.'",
      'Sample input: From now on I prefer concise answers.',
      'Suppose I said: going forward I prefer concise answers.',
      '    Going forward, I prefer concise answers.',
      '[2026-07-22 10:00] INFO Going forward, I prefer concise answers.',
      '2026-07-22 10:00 INFO Going forward, I prefer concise answers.',
      'Render this into French: Going forward, I prefer concise answers.',
      'Remember that Bob prefers concise answers.',
      'Bob says going forward you should be concise.',
      'Going forward, I prefer not to receive concise answers.',
      (@('Example:','Going forward, I prefer concise answers by default.') -join "`n"),
      (@('Sample input:','Going forward, I prefer concise answers by default.') -join "`n"),
      (@('Log:','Going forward, I prefer concise answers by default.') -join "`n"),
      (@('Log:','Going forward, I prefer concise answers by default.','','Going forward, I prefer detailed answers.') -join "`n"),
      (@('For this task:','Going forward, I prefer concise answers by default.') -join "`n"),
      (@([regex]::Unescape('\u672c\u4efb\u52a1\uff1a'),[regex]::Unescape('\u4ee5\u540e\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54\u3002')) -join "`n"),
      'Going forward, I prefer concise answers. Going forward, I prefer detailed answers.',
      'Remember that my teammate wants you to answer concisely.',
      ([regex]::Unescape('\u4ee5\u540e\u8bf7\u8bb0\u4f4f\u6211\u7684\u540c\u4e8b\u504f\u597d\u7b80\u6d01\u56de\u7b54\u3002'))
    )
    foreach ($prompt in $prompts) {
      $run = Invoke-TestHookProcess $stateRoot $prompt
      $run.exitCode | Should Be 0
      if (-not [string]::IsNullOrWhiteSpace($run.output)) {
        (($run.output | ConvertFrom-Json).hookSpecificOutput.additionalContext -match 'USER_ADAPTATION_SIGNAL') | Should Be $false
      }
    }
    (Test-Path (Join-Path $stateRoot 'workspace\user-adaptation')) | Should Be $false
  }

  # Retired P7 fixture retained as historical reference; H7 turn-runtime and
  # direct adaptation APIs are the current acceptance paths.
  It 'keeps a trusted direct clause beside an example and binds declared project scope' -Skip {
    $stateRoot = Join-Path $TestDrive 'hook-trusted-clause-scope'
    $workspace = Join-Path $stateRoot 'workspace'
    $null = Initialize-TestV2AdaptationStore $workspace
    $prompt = 'For this project, going forward I prefer concise answers. For example, another assistant may be detailed.'
    $run = Invoke-TestHookProcess $stateRoot $prompt
    $run.exitCode | Should Be 0
    ($run.output | ConvertFrom-Json).hookSpecificOutput.additionalContext.Contains('USER_ADAPTATION_SIGNAL') | Should Be $true
    $store = Get-UserAdaptationV2Store $Root $workspace
    @($store.observations).Count | Should Be 1
    $observation = @($store.observations)[0]
    $observation.habitKey | Should Be 'response_detail'
    $observation.value | Should Be 'concise'
    $observation.scope | Should Be 'project'
    $observation.scopeKey | Should Be (Get-SuperBrainWorkspaceKey $Root)
    $observation.source | Should Be 'explicit_user'

    $blockStateRoot=Join-Path $TestDrive 'hook-closed-example-block';$blockWorkspace=Join-Path $blockStateRoot 'workspace';$null=Initialize-TestV2AdaptationStore $blockWorkspace
    $blockPrompt=@('Example:','Going forward, I prefer concise answers by default.','','For this project, going forward I prefer detailed answers.')-join"`n"
    $blockRun=Invoke-TestHookProcess $blockStateRoot $blockPrompt
    $blockRun.exitCode|Should Be 0
    $blockStore=Get-UserAdaptationV2Store $Root $blockWorkspace
    @($blockStore.observations).Count|Should Be 1
    $blockStore.observations[0].value|Should Be 'detailed'

    $declaredStateRoot=Join-Path $TestDrive 'hook-declared-project-block';$declaredWorkspace=Join-Path $declaredStateRoot 'workspace';$null=Initialize-TestV2AdaptationStore $declaredWorkspace
    $declaredPrompt=@('For this project:','Going forward, I prefer concise answers by default.')-join"`n"
    $declaredRun=Invoke-TestHookProcess $declaredStateRoot $declaredPrompt
    $declaredRun.exitCode|Should Be 0
    $declaredStore=Get-UserAdaptationV2Store $Root $declaredWorkspace
    @($declaredStore.observations).Count|Should Be 1
    $declaredStore.observations[0].scope|Should Be 'project'

    $closedLogStateRoot=Join-Path $TestDrive 'hook-closed-log-block';$closedLogWorkspace=Join-Path $closedLogStateRoot 'workspace';$null=Initialize-TestV2AdaptationStore $closedLogWorkspace
    $closedLogPrompt=@('Log:','Going forward, I prefer concise answers by default.','End log','Going forward, I prefer detailed answers.')-join"`n"
    $closedLogRun=Invoke-TestHookProcess $closedLogStateRoot $closedLogPrompt
    $closedLogRun.exitCode|Should Be 0
    $closedLogStore=Get-UserAdaptationV2Store $Root $closedLogWorkspace
    @($closedLogStore.observations).Count|Should Be 1
    $closedLogStore.observations[0].value|Should Be 'detailed'
  }

  # Retired P7 fixture retained as historical reference; H7 turn-runtime and
  # direct adaptation APIs are the current acceptance paths.
  It 'captures an explicit V2 preference once and replays the same prompt without a transition conflict' -Skip {
    $stateRoot = Join-Path $TestDrive 'hook-v2-idempotent'
    $workspace = Join-Path $stateRoot 'workspace'
    $null = Initialize-TestV2AdaptationStore $workspace
    $prompt = 'Going forward, I prefer warm and direct wording by default.'
    $first = Invoke-TestHookProcess $stateRoot $prompt
    $second = Invoke-TestHookProcess $stateRoot $prompt
    $first.exitCode | Should Be 0
    $second.exitCode | Should Be 0
    ($first.output | ConvertFrom-Json).hookSpecificOutput.additionalContext.Contains('USER_ADAPTATION_SIGNAL') | Should Be $true
    ($second.output | ConvertFrom-Json).hookSpecificOutput.additionalContext.Contains('USER_ADAPTATION_SIGNAL') | Should Be $true
    $store = Get-UserAdaptationV2Store $Root $workspace
    @($store.observations).Count | Should Be 1
    @($store.profile | Where-Object { $_.habitKey -eq 'speaking_style' -and $_.value -eq 'warm_direct' -and $_.status -eq 'active' }).Count | Should Be 1
    @($store.receipts | Where-Object { $_.transitionId -match '^hook-' }).Count | Should Be 2
  }

  # Retired P7 fixture retained as historical reference; H7 turn-runtime and
  # direct adaptation APIs are the current acceptance paths.
  It 'captures a real hook preference and exposes it only through relevant preflight' -Skip {
    $stateRoot = Join-Path $TestDrive 'hook-apply-mode'
    $null = Initialize-TestV2AdaptationStore (Join-Path $stateRoot 'workspace')
    $prompt = 'From now on, I prefer concise answers by default.'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'powershell.exe'
    $start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Hook`""
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['SUPER_BRAIN_STATE_ROOT'] = $stateRoot
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.Write((@{prompt=$prompt} | ConvertTo-Json -Compress))
    $process.StandardInput.Close()
    $hookOutput = $process.StandardOutput.ReadToEnd()
    $hookError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $process.ExitCode | Should Be 0
    ($hookOutput | ConvertFrom-Json).hookSpecificOutput.additionalContext.Contains('USER_ADAPTATION_SIGNAL') | Should Be $true

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $preflight = (& $Preflight -Query 'implement a small code module' -Json | ConvertFrom-Json)
      $preflight.userAdaptation.directiveCount | Should Be 1
      @($preflight.cards | Where-Object { $_.kind -eq 'user_adaptation' }).Count | Should Be 1
      $stored = @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
      $stored.Contains($prompt) | Should Be $false
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }

  It 'keeps maintenance read-only in plan mode and synthesizes only with ApplySafe' {
    $stateRoot = Join-Path $TestDrive 'maintenance-integration'
    $workspace = Join-Path $stateRoot 'workspace'
    $null = Add-TestAdaptationObservation $workspace response_detail concise task-1 coding
    $null = Add-TestAdaptationObservation $workspace response_detail concise task-2 coding
    $null = Add-TestAdaptationObservation $workspace response_detail concise task-3 debugging
    $staged=Invoke-TestAdaptationSynthesis $workspace
    $staged.stagedPreferenceCount|Should Be 1
    $null = Add-TestAdaptationObservation $workspace response_detail concise task-4 debugging
    $storePath=(Get-UserAdaptationPaths $Root $workspace).storeV2
    $beforePlanHash=Get-SuperBrainFileSha256 $storePath
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $plan = (& $Maintenance -Summary 'adaptation integration test' -Json | ConvertFrom-Json)
      ($plan.steps | Where-Object { $_.name -eq 'user-adaptation' }).rawPreview.Contains('"action":  "Status"') | Should Be $true
      (Get-SuperBrainFileSha256 $storePath) | Should Be $beforePlanHash

      $apply = (& $Maintenance -Summary 'adaptation integration test' -ApplySafe -Json | ConvertFrom-Json)
      ($apply.steps | Where-Object { $_.name -eq 'user-adaptation' }).rawPreview.Contains('"action":  "Synthesize"') | Should Be $true
      (Get-SuperBrainFileSha256 $storePath) | Should Not Be $beforePlanHash
      (Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $workspace).activePreferenceCount | Should Be 1
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }

  It 'previews verified outcome signals without mutating adaptation state' {
    $workspaceKey = 'ws-aaaaaaaaaaaaaaaaaaaaaaaa'
    $result = Invoke-TestAdaptationObserver $script:AdaptationWorkspace preview-task $workspaceKey @('response_detail=concise') Preview
    $result.ok | Should Be $true
    $result.verificationMatch | Should Be $false
    $result.appliedCount | Should Be 0
    (Test-Path (Join-Path $script:AdaptationWorkspace 'user-adaptation\observations.json')) | Should Be $false
  }

  It 'rejects missing and mismatched verification artifacts' {
    $workspaceKey = 'ws-bbbbbbbbbbbbbbbbbbbbbbbb'
    $missing = Invoke-TestAdaptationObserver $script:AdaptationWorkspace missing-task $workspaceKey @('response_detail=concise')
    $missing.ok | Should Be $false
    $missing.error | Should Be 'USER_ADAPTATION_OBSERVER_VERIFIED_ARTIFACT_REQUIRED'

    Set-TestVerifiedOutcome $script:AdaptationWorkspace another-task $workspaceKey
    $mismatched = Invoke-TestAdaptationObserver $script:AdaptationWorkspace expected-task $workspaceKey @('response_detail=concise')
    $mismatched.ok | Should Be $false
    $mismatched.error | Should Be 'USER_ADAPTATION_OBSERVER_VERIFIED_ARTIFACT_REQUIRED'
    (Test-Path (Join-Path $script:AdaptationWorkspace 'user-adaptation\observations.json')) | Should Be $false
  }

  It 'accepts only the exact canonical V2 verification artifact and its current hash' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-444444444444444444444444'
    Set-TestVerifiedOutcome $script:AdaptationWorkspace canonical-task $workspaceKey
    $mutable = Invoke-TestAdaptationObserver $script:AdaptationWorkspace canonical-task $workspaceKey @('response_detail=concise')
    $mutable.ok | Should Be $false
    $mutable.error | Should Be 'USER_ADAPTATION_OBSERVER_VERIFIED_ARTIFACT_REQUIRED'

    $sourceArtifact = Set-TestCanonicalVerifiedOutcome $script:AdaptationWorkspace canonical-task $workspaceKey
    $verificationRoot = Join-Path $script:AdaptationWorkspace 'runtime-state\user-adaptation-verifications'
    $forgedPath = Join-Path $verificationRoot 'matching-content-wrong-name.json'
    Copy-Item -LiteralPath $sourceArtifact.path -Destination $forgedPath
    $forged = Invoke-TestAdaptationObserver $script:AdaptationWorkspace canonical-task $workspaceKey @('response_detail=concise') Apply coding accepted_outcome '' '' @() $forgedPath
    $forged.ok | Should Be $false
    $forged.error | Should Be 'USER_ADAPTATION_OBSERVER_IMMUTABLE_VERIFICATION_REQUIRED'

    $canonicalArtifact = $sourceArtifact
    $canonicalPath = $canonicalArtifact.path
    $accepted = Invoke-TestAdaptationObserver $script:AdaptationWorkspace canonical-task $workspaceKey @('response_detail=concise') Apply coding accepted_outcome '' '' @() $canonicalPath
    $accepted.ok | Should Be $true
    $accepted.appliedCount | Should Be 1
    $store = Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace
    @($store.observations)[0].verificationHash | Should Be (Get-SuperBrainFileSha256 $canonicalPath)

    $tamperedArtifact = Set-TestCanonicalVerifiedOutcome $script:AdaptationWorkspace tampered-task $workspaceKey
    $tamperedPath = $tamperedArtifact.path
    $tamperError = ''
    try {
      $null = Add-UserAdaptationObservation -Root $Root -HabitKey response_detail -Value concise -Source accepted_outcome -Scope project -ScopeKey $workspaceKey -Context coding -TaskId tampered-task -EvidenceRef tampered-task -WorkspaceRoot $script:AdaptationWorkspace -EvidenceKind verified_outcome -Producer task_verification -ExpectedRevision $store.revision -TransitionId tampered-task -VerificationArtifactPath $tamperedPath -VerificationHash ('0' * 64)
    } catch { $tamperError = $_.Exception.Message }
    $tamperError | Should Match 'USER_ADAPTATION_VERIFICATION_ARTIFACT_MISMATCH'
  }

  It 'records bounded workflow measurements only through a verified task protocol' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-555555555555555555555555'
    $measurement = 'review_protocol=multi_pass;forwardPasses=3;reversePasses=2;riskFloor=structural;contexts=coding,review'
    $canonicalArtifact = Set-TestCanonicalVerifiedOutcome $script:AdaptationWorkspace measured-review $workspaceKey @() @($measurement) accepted_outcome review code-review
    $canonicalPath = $canonicalArtifact.path
    $accepted = Invoke-TestAdaptationObserver $script:AdaptationWorkspace measured-review $workspaceKey @() Apply review accepted_outcome code-review '' @($measurement) $canonicalPath
    $accepted.ok | Should Be $true
    $accepted.appliedCount | Should Be 1
    $accepted.scope | Should Be 'workflow'
    $accepted.signals[0].evidenceKind | Should Be 'workflow_measurement'
    $observation = @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).observations)[0]
    $observation.producer | Should Be 'verified_task_protocol'
    $observation.parameters.forwardPasses | Should Be 3
    $observation.parameters.reversePasses | Should Be 2
    $observation.parameters.riskFloor | Should Be 'structural'
    @($observation.parameters.contexts) | Should Be @('coding','review')
    $observation.verificationHash | Should Be (Get-SuperBrainFileSha256 $canonicalPath)

    $mismatchTask='measured-risk-mismatch'
    $mismatchArtifact=Set-TestCanonicalVerifiedOutcome $script:AdaptationWorkspace $mismatchTask $workspaceKey @() @($measurement) accepted_outcome review code-review
    $workflowReceipt=New-TestUserAdaptationConfirmationReceiptFixture -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -TaskId $mismatchTask -TaskInstanceId 'ti-99999999999999999999999999999999' -WorkspaceKey $workspaceKey -OwnerSessionKey 'sid-riskmismatch1234' -ContractRevision 1 -PlanFingerprint ('4'*16) -PlanId 'plan-risk-mismatch' -PlanGeneration 1 -PlanOriginFingerprint ('5'*16) -CanonicalFingerprint ('6'*16) -Context review -Scope workflow -WorkflowKey code-review -Signals @() -ProtocolBinding ([pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='workflow';contexts=@('coding','review')}) -InstructionSha256 ('f'*64)
    $mismatchRecord=Get-Content -LiteralPath $mismatchArtifact.path -Raw -Encoding UTF8|ConvertFrom-Json
    $mismatchRecord.confirmationReceipt=[pscustomobject]@{relativePath=$workflowReceipt.relativePath;sha256=$workflowReceipt.sha256;selectionHash=$workflowReceipt.selectionHash}
    $mismatchRoot=Join-Path $script:AdaptationWorkspace 'runtime-state\user-adaptation-verifications';$pending=Join-Path $mismatchRoot ('.risk-mismatch-'+[guid]::NewGuid().ToString('n')+'.json')
    Write-TestAdaptationJson $pending $mismatchRecord;$mismatchHash=Get-SuperBrainFileSha256 $pending;$mismatchPath=Join-Path $mismatchRoot ((Get-SuperBrainCanonicalTaskToken $mismatchTask)+'--'+$mismatchHash+'.json');Move-Item -LiteralPath $pending -Destination $mismatchPath
    $riskMismatch=Invoke-TestAdaptationObserver $script:AdaptationWorkspace $mismatchTask $workspaceKey @() Apply review accepted_outcome code-review '' @($measurement) $mismatchPath
    $riskMismatch.ok|Should Be $false
    $riskMismatch.error|Should Be 'USER_ADAPTATION_CONFIRMATION_PROTOCOL_MISMATCH'
    (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).observationCount|Should Be 1

    (Invoke-TestAdaptationObserver $script:AdaptationWorkspace measured-review-2 $workspaceKey @() Apply review accepted_outcome '' '' @($measurement)).error | Should Be 'USER_ADAPTATION_OBSERVER_MEASUREMENT_SCOPE_INVALID'
    (Invoke-TestAdaptationObserver $script:AdaptationWorkspace measured-review-3 $workspaceKey @() Apply review user_correction code-review '' @($measurement)).error | Should Be 'USER_ADAPTATION_OBSERVER_MEASUREMENT_SCOPE_INVALID'
    (Invoke-TestAdaptationObserver $script:AdaptationWorkspace measured-review-4 $workspaceKey @() Apply review accepted_outcome code-review '' @('review_protocol=multi_pass;forwardPasses=9;reversePasses=2;riskFloor=structural')).error | Should Be 'USER_ADAPTATION_OBSERVER_MEASUREMENT_INVALID'
  }

  It 'rejects producer and source evidence mismatches before any V2 write' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-666666666666666666666666'
    $canonicalArtifact = Set-TestCanonicalVerifiedOutcome $script:AdaptationWorkspace source-mismatch $workspaceKey
    $canonicalPath = $canonicalArtifact.path
    $producerError = ''
    try {
      $null = Add-UserAdaptationObservation -Root $Root -HabitKey response_detail -Value concise -Source accepted_outcome -Scope project -ScopeKey $workspaceKey -Context coding -TaskId source-mismatch -EvidenceRef source-mismatch -WorkspaceRoot $script:AdaptationWorkspace -EvidenceKind verified_outcome -Producer trusted_direct_statement -ExpectedRevision 1 -TransitionId bad-producer -VerificationArtifactPath $canonicalPath -VerificationHash (Get-SuperBrainFileSha256 $canonicalPath)
    } catch { $producerError = $_.Exception.Message }
    $producerError | Should Be 'USER_ADAPTATION_PRODUCER_MISMATCH'

    $sourceError = ''
    try {
      $null = Add-UserAdaptationObservation -Root $Root -HabitKey response_detail -Value concise -Source explicit_user -Scope project -ScopeKey $workspaceKey -Context coding -TaskId source-mismatch -EvidenceRef source-mismatch -WorkspaceRoot $script:AdaptationWorkspace -EvidenceKind verified_outcome -Producer task_verification -ExpectedRevision 1 -TransitionId bad-source -VerificationArtifactPath $canonicalPath -VerificationHash (Get-SuperBrainFileSha256 $canonicalPath)
    } catch { $sourceError = $_.Exception.Message }
    $sourceError | Should Be 'USER_ADAPTATION_SOURCE_EVIDENCE_MISMATCH'
    (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).observationCount | Should Be 0
  }

  It 'requires a closed correction candidate target preference and verification hash in V2' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-777777777777777777777777'
    $canonicalArtifact = Set-TestCanonicalVerifiedOutcome $script:AdaptationWorkspace correction-gates $workspaceKey @('feature_thinking=integrated') @() user_correction coding '' 'correction-stage3-gates' 'pref-does-not-exist'
    $canonicalPath = $canonicalArtifact.path
    $missingCandidate = Invoke-TestAdaptationObserver $script:AdaptationWorkspace correction-gates $workspaceKey @('feature_thinking=integrated') Apply coding user_correction '' '' @() $canonicalPath
    $missingCandidate.error | Should Be 'USER_ADAPTATION_OBSERVER_CLOSED_CORRECTION_REQUIRED'

    $candidateId = 'correction-stage3-gates'
    $candidatePath = Join-Path $script:AdaptationWorkspace "reflection\correction-candidates\$candidateId.json"
    Write-TestAdaptationJson $candidatePath ([pscustomobject]@{schema='super-brain.correction-candidate.v1';candidateId=$candidateId;workspaceKey=$workspaceKey;status='closed';closedAt='2026-07-22T00:00:00Z';closureReason='verified_fix_outcome';analysisSummaryHash=('b'*24);promotionCandidateIds=@('promotion-gate');durablePromotionAllowed=$true;rawPromptStored=$false;autonomyEvidenceLink=[pscustomobject]@{eligible=$true;taskId='correction-gates';verifiedOutcomeRecordId='verified-task-correction-gates';verifiedOutcomeSha256=$canonicalArtifact.outcomeSha256;rawPromptStored=$false}})
    $missingTarget = Invoke-TestAdaptationObserver $script:AdaptationWorkspace correction-gates $workspaceKey @('feature_thinking=integrated') Apply coding user_correction '' $candidateId @() $canonicalPath
    $missingTarget.error | Should Be 'USER_ADAPTATION_OBSERVER_CORRECTION_TARGET_REQUIRED'
    $invalidTarget = Invoke-TestAdaptationObserver $script:AdaptationWorkspace correction-gates $workspaceKey @('feature_thinking=integrated') Apply coding user_correction '' $candidateId @() $canonicalPath pref-does-not-exist
    $invalidTarget.error | Should Be 'USER_ADAPTATION_CORRECTION_TARGET_INVALID'
    (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).observationCount | Should Be 0
  }

  It 'defers correction learning until reflection closes the verified candidate' {
    $stateRoot=Join-Path $TestDrive 'correction-close';$workspace=Join-Path $stateRoot 'workspace';$workspaceKey='ws-121212121212121212121212';$candidateId='correction-deferred-close'
    $null=Initialize-TestV2AdaptationStore $workspace;$revision=1
    foreach($sample in @(@('base-1','coding','2026-07-20'),@('base-2','debugging','2026-07-20'),@('base-3','coding','2026-07-21'),@('base-4','debugging','2026-07-21'))){$observed=Add-TestV2VerifiedObservation -WorkspaceRoot $workspace -HabitKey response_detail -Value concise -Scope project -ScopeKey $workspaceKey -Context $sample[1] -TaskId $sample[0] -EvidenceDate $sample[2] -ExpectedRevision $revision;$revision=$observed.revision}
    $stage=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $workspace -ExpectedRevision $revision
    $fifth=Add-TestV2VerifiedObservation -WorkspaceRoot $workspace -HabitKey response_detail -Value concise -Scope project -ScopeKey $workspaceKey -Context coding -TaskId base-5 -EvidenceDate '2026-07-22' -ExpectedRevision $stage.revision
    $active=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $workspace -ExpectedRevision $fifth.revision
    $targetPreferenceId=[string]@((Get-UserAdaptationV2Store $Root $workspace).profile|Where-Object{$_.status-eq'active'})[0].preferenceId
    $artifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $workspace -TaskId correction-fix -WorkspaceKey $workspaceKey -Signals @('response_detail=detailed') -Source user_correction -Context coding -CorrectionCandidateId $candidateId -CorrectionTargetPreferenceId $targetPreferenceId
    $candidatePath=Join-Path $workspace "reflection\correction-candidates\$candidateId.json"
    Write-TestAdaptationJson $candidatePath ([pscustomobject]@{schema='super-brain.correction-candidate.v1';candidateId=$candidateId;capturedAt='2026-07-22T00:00:00Z';promptHash='abcdef123456';promptLength=40;signals=@('strong_correction');workspaceKey=$workspaceKey;status='analyzed';analysisSummary='Verified correction replaces the inferred concise default for this project.';analysisSummaryHash=('c'*24);analysisScope='project';rawPromptStored=$false;durablePromotionAllowed=$false})
    $requestRoot=Join-Path $workspace 'runtime-state\user-adaptation-correction-requests';$requestPath=Join-Path $requestRoot ($candidateId+'.json');$artifactRelative=$artifact.path.Substring($workspace.Length).TrimStart('\','/')-replace'\\','/'
    $requestRecord=[pscustomobject]@{schema='super-brain.user-adaptation-correction-request.v1';candidateId=$candidateId;taskId='correction-fix';workspaceKey=$workspaceKey;context='coding';workflowKey='';signals=@('response_detail=detailed');targetPreferenceId=$targetPreferenceId;verificationArtifactRelativePath='runtime-state/user-adaptation-verifications/missing.json';verificationHash=$artifact.sha256;status='pending_correction_close';createdAt='2026-07-22T00:00:00Z';requestHash=('d'*64);rawPromptStored=$false;rawSummaryStored=$false}
    Write-TestAdaptationJson $requestPath $requestRecord
    $oldStateRoot=$env:SUPER_BRAIN_STATE_ROOT
    try{
      $env:SUPER_BRAIN_STATE_ROOT=$stateRoot
      $failedRaw=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ReflectionPromotion -Mode Apply -TriggerType user_correction -Summary 'The verified correction replaces the inferred concise default with detailed project responses and keeps all evidence task scoped.' -Evidence "correctionCandidate=$candidateId" -Scope project -WorkspaceRoot $workspace -Json 2>$null)
      $LASTEXITCODE|Should Be 1
      $failed=(($failedRaw-join"`n")|ConvertFrom-Json)
      $failed.ok|Should Be $false
      $failed.linkedCorrectionCandidate.status|Should Be 'closing'
      (Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8|ConvertFrom-Json).status|Should Be 'failed_retryable'
      @((Get-UserAdaptationV2Store $Root $workspace).observations|Where-Object{$_.evidenceKind-eq'verified_correction'}).Count|Should Be 0

      $requestRecord=Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8|ConvertFrom-Json
      $requestRecord.verificationArtifactRelativePath=$artifactRelative
      Write-TestAdaptationJson $requestPath $requestRecord
      $raw=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ReflectionPromotion -Mode Apply -TriggerType user_correction -Summary 'The verified correction replaces the inferred concise default with detailed project responses and keeps all evidence task scoped.' -Evidence "correctionCandidate=$candidateId" -Scope project -WorkspaceRoot $workspace -Json 2>$null)
      $LASTEXITCODE|Should Be 0
      $result=(($raw-join"`n")|ConvertFrom-Json)
      $result.recovered|Should Be $true
      $result.replayed|Should Be $false
      $result.linkedCorrectionCandidate.status|Should Be 'closed'
      $result.correctionAdaptation.ok|Should Be $true
      $result.correctionAdaptation.appliedCount|Should Be 1
      @((Get-UserAdaptationV2Store $Root $workspace).profile|Where-Object{$_.preferenceId-eq$targetPreferenceId})[0].status|Should Be 'dormant'
      @((Get-UserAdaptationV2Store $Root $workspace).observations|Where-Object{$_.evidenceKind-eq'verified_correction'}).Count|Should Be 1
      (Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8|ConvertFrom-Json).status|Should Be 'applied'
      $requestHashBeforeReplay=Get-SuperBrainFileSha256 $requestPath;$candidateHashBeforeReplay=Get-SuperBrainFileSha256 $candidatePath
      $replayRaw=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ReflectionPromotion -Mode Apply -TriggerType user_correction -Summary 'The verified correction replaces the inferred concise default with detailed project responses and keeps all evidence task scoped.' -Evidence "correctionCandidate=$candidateId" -Scope project -WorkspaceRoot $workspace -Json 2>$null)
      $LASTEXITCODE|Should Be 0
      $replay=(($replayRaw-join"`n")|ConvertFrom-Json)
      $replay.replayed|Should Be $true
      $replay.correctionAdaptation.reason|Should Be 'verified_correction_already_applied'
      $replay.correctionAdaptation.appliedCount|Should Be 1
      (Get-SuperBrainFileSha256 $requestPath)|Should Be $requestHashBeforeReplay
      (Get-SuperBrainFileSha256 $candidatePath)|Should Be $candidateHashBeforeReplay
      @((Get-UserAdaptationV2Store $Root $workspace).observations|Where-Object{$_.evidenceKind-eq'verified_correction'}).Count|Should Be 1
    }finally{$env:SUPER_BRAIN_STATE_ROOT=$oldStateRoot}
  }

  It 'isolates learned project and workflow preferences by workspace' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-cccccccccccccccccccccccc'
    $foreignKey = 'ws-dddddddddddddddddddddddd'
    foreach ($sample in @(@('project-1','coding','2026-07-20'),@('project-2','debugging','2026-07-20'),@('project-3','coding','2026-07-21'),@('project-4','debugging','2026-07-21'))) {
      (Invoke-TestVerifiedAdaptationObserver $script:AdaptationWorkspace $sample[0] $workspaceKey @('response_detail=concise') $sample[1] accepted_outcome '' @() '' '' $sample[2]).ok | Should Be $true
    }
    $stageProject=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision
    (Invoke-TestVerifiedAdaptationObserver $script:AdaptationWorkspace project-5 $workspaceKey @('response_detail=concise') coding accepted_outcome '' @() '' '' '2026-07-22').ok | Should Be $true
    $activeProject=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision

    foreach ($sample in @(@('workflow-1','review','2026-07-20'),@('workflow-2','coding','2026-07-20'),@('workflow-3','review','2026-07-21'),@('workflow-4','coding','2026-07-21'))) {
      (Invoke-TestVerifiedAdaptationObserver $script:AdaptationWorkspace $sample[0] $workspaceKey @('reasoning_style=evidence_first') $sample[1] accepted_outcome code-review @() '' '' $sample[2]).scopeKey | Should Be "$workspaceKey`:code-review"
    }
    $stageWorkflow=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision
    (Invoke-TestVerifiedAdaptationObserver $script:AdaptationWorkspace workflow-5 $workspaceKey @('reasoning_style=evidence_first') review accepted_outcome code-review @() '' '' '2026-07-22').ok | Should Be $true
    $activeWorkflow=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision

    (@((Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceKey $workspaceKey -WorkflowKey other -WorkspaceRoot $script:AdaptationWorkspace).preferences.value) -contains 'concise') | Should Be $true
    (Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceKey $foreignKey -WorkflowKey other -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
    (@((Get-UserAdaptationPacket -Root $Root -Context review -WorkspaceKey $workspaceKey -WorkflowKey code-review -WorkspaceRoot $script:AdaptationWorkspace).preferences.value) -contains 'evidence_first') | Should Be $true
    (Get-UserAdaptationPacket -Root $Root -Context review -WorkspaceKey $foreignKey -WorkflowKey code-review -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
  }

  It 'enforces the three-signal task budget' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-eeeeeeeeeeeeeeeeeeeeeeee'
    $revisionBefore = [int](Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).revision
    $signals=@('response_detail=concise','reasoning_style=evidence_first','proactivity=material_only')
    $artifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $script:AdaptationWorkspace -TaskId budget-task -WorkspaceKey $workspaceKey -Signals $signals
    $accepted = Invoke-TestAdaptationObserver $script:AdaptationWorkspace budget-task $workspaceKey $signals Apply coding accepted_outcome '' '' @() $artifact.path
    $accepted.ok | Should Be $true
    $accepted.appliedCount | Should Be 3
    $accepted.batchRevision | Should Be ($revisionBefore + 1)
    $storeAfterBatch = Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace
    [int]$storeAfterBatch.revision | Should Be ($revisionBefore + 1)
    $batchReceipt=@($storeAfterBatch.receipts | Where-Object { $_.kind -eq 'observation_batch' })[0]
    @($batchReceipt.identityHashes).Count | Should Be 3
    $items=@([pscustomobject]@{habitKey='reasoning_style';value='evidence_first'},[pscustomobject]@{habitKey='proactivity';value='material_only'},[pscustomobject]@{habitKey='response_detail';value='concise'})
    $memberText=@($items|ForEach-Object{"$($_.habitKey)=$($_.value)"}|Sort-Object)-join'|'
    $transition='observer-batch-'+(Get-UserAdaptationHash "budget-task|$($artifact.sha256)|$memberText" 8)
    $replay=Add-UserAdaptationObservationBatchV2 -Root $Root -Items $items -Source accepted_outcome -Scope project -ScopeKey $workspaceKey -Context coding -TaskId budget-task -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $revisionBefore -TransitionId $transition -VerificationArtifactPath $artifact.path -VerificationHash $artifact.sha256
    $replay.replayed | Should Be $true
    $bindingConflict=''
    try{$null=Add-UserAdaptationObservationBatchV2 -Root $Root -Items $items -Source accepted_outcome -Scope project -ScopeKey $workspaceKey -Context coding -TaskId budget-task -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $revisionBefore -TransitionId $transition -VerificationArtifactPath $artifact.path -VerificationHash $artifact.sha256 -CorrectionTargetPreferenceId pref-changed-target}catch{$bindingConflict=$_.Exception.Message}
    $bindingConflict | Should Be 'USER_ADAPTATION_TRANSITION_ID_CONFLICT'

    Set-TestVerifiedOutcome $script:AdaptationWorkspace overflow-task $workspaceKey
    $rejected = Invoke-TestAdaptationObserver $script:AdaptationWorkspace overflow-task $workspaceKey @('response_detail=concise','reasoning_style=evidence_first','proactivity=material_only','verification_depth=risk_based')
    $rejected.ok | Should Be $false
    $rejected.error | Should Be 'USER_ADAPTATION_OBSERVER_SIGNAL_BUDGET_EXCEEDED'
    (Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).observationCount | Should Be 3
  }

  It 'rejects a caller subset of the verified exact signal set without writing' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-aeaeeaeaeaeaeaeaeaeaeaea'
    $artifact = Write-TestAdaptationVerificationArtifact -WorkspaceRoot $script:AdaptationWorkspace -TaskId exact-set-task -WorkspaceKey $workspaceKey -Signals @('response_detail=concise','reasoning_style=evidence_first')
    $before = Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace
    $result = Invoke-TestAdaptationObserver $script:AdaptationWorkspace exact-set-task $workspaceKey @('response_detail=concise') Apply coding accepted_outcome '' '' @() $artifact.path
    $result.ok | Should Be $false
    $result.error | Should Be 'USER_ADAPTATION_OBSERVATION_BATCH_EXACT_SET_MISMATCH'
    $after = Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace
    $after.revision | Should Be $before.revision
    $after.observationCount | Should Be 0
  }

  It 'rolls back every member when a later batch member is blocked' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-abababababababababababab'
    $revision = [int](Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision
    $explicit = Add-UserAdaptationObservation -Root $Root -HabitKey response_detail -Value concise -Signal Support -Source explicit_user -Scope project -ScopeKey $workspaceKey -Context coding -TaskId tombstone-seed -EvidenceRef tombstone-seed -WorkspaceRoot $script:AdaptationWorkspace -EvidenceKind durable_explicit -Producer trusted_direct_statement -ExpectedRevision $revision -TransitionId tombstone-seed-observe
    $synthesis = Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int]$explicit.revision) -TransitionId tombstone-seed-synthesis
    $preference = @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile | Where-Object { $_.habitKey -eq 'response_detail' -and $_.status -eq 'active' })[0]
    $forgotten = Remove-UserAdaptationPreference -Root $Root -PreferenceId $preference.preferenceId -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int]$synthesis.revision) -TransitionId tombstone-seed-forget -Confirmed
    $forgotten.ok | Should Be $true
    $artifact = Write-TestAdaptationVerificationArtifact -WorkspaceRoot $script:AdaptationWorkspace -TaskId atomic-failure-task -WorkspaceKey $workspaceKey -Signals @('reasoning_style=evidence_first','response_detail=detailed')
    $storePath = (Get-UserAdaptationPaths $Root $script:AdaptationWorkspace).storeV2
    $hashBefore = Get-SuperBrainFileSha256 $storePath
    $revisionBefore = [int](Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision
    $result = Invoke-TestAdaptationObserver $script:AdaptationWorkspace atomic-failure-task $workspaceKey @('reasoning_style=evidence_first','response_detail=detailed') Apply coding accepted_outcome '' '' @() $artifact.path
    $result.ok | Should Be $false
    $result.error | Should Be 'USER_ADAPTATION_REINSTATE_REQUIRED'
    (Get-SuperBrainFileSha256 $storePath) | Should Be $hashBefore
    $after = Get-UserAdaptationStatus $Root $script:AdaptationWorkspace
    $after.revision | Should Be $revisionBefore
    $after.observationCount | Should Be 0
  }

  It 'preserves the store and removes pending files when atomic replacement is faulted' {
    $null=Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey='ws-bcbcbcbcbcbcbcbcbcbcbcbc'
    $artifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $script:AdaptationWorkspace -TaskId publish-fault-task -WorkspaceKey $workspaceKey -Signals @('response_detail=concise')
    $paths=Get-UserAdaptationPaths $Root $script:AdaptationWorkspace
    $hashBefore=Get-SuperBrainFileSha256 $paths.storeV2
    $revisionBefore=[int](Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision
    $failure=''
    try{$null=Add-UserAdaptationObservationBatchV2 -Root $Root -Items @([pscustomobject]@{habitKey='response_detail';value='concise'}) -Source accepted_outcome -Scope project -ScopeKey $workspaceKey -Context coding -TaskId publish-fault-task -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision $revisionBefore -TransitionId publish-fault-batch -VerificationArtifactPath $artifact.path -VerificationHash $artifact.sha256 -FaultPoint before_replace}catch{$failure=$_.Exception.Message}
    $failure | Should Be 'USER_ADAPTATION_FAULT_BEFORE_STORE_REPLACE'
    (Get-SuperBrainFileSha256 $paths.storeV2) | Should Be $hashBefore
    (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision | Should Be $revisionBefore
    @(Get-ChildItem -LiteralPath $paths.directory -File -Filter '.pending-*' -ErrorAction SilentlyContinue).Count | Should Be 0
    @(Get-ChildItem -LiteralPath $paths.directory -File -Filter '.replace-backup-*' -ErrorAction SilentlyContinue).Count | Should Be 0
  }

  It 'removes a multi-identity batch receipt when either bound identity is forgotten' {
    $null=Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey='ws-cacacacacacacacacacacaca'
    $revision=[int](Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision
    $observed=Add-UserAdaptationObservation -Root $Root -HabitKey response_detail -Value concise -Signal Support -Source explicit_user -Scope project -ScopeKey $workspaceKey -Context coding -TaskId receipt-forget-seed -EvidenceRef receipt-forget-seed -WorkspaceRoot $script:AdaptationWorkspace -EvidenceKind durable_explicit -Producer trusted_direct_statement -ExpectedRevision $revision -TransitionId receipt-forget-observe
    $synthesized=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int]$observed.revision) -TransitionId receipt-forget-synthesis
    $paths=Get-UserAdaptationPaths $Root $script:AdaptationWorkspace
    $responseIdentity=(Get-UserAdaptationIdentity project $workspaceKey response_detail).hash
    $reasoningIdentity=(Get-UserAdaptationIdentity project $workspaceKey reasoning_style).hash
    Invoke-SuperBrainFileLock $paths.coordination {
      $store=Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace
      $from=[int]$store.revision;$store.revision=$from+1;$store.updatedAt=(Get-Date).ToString('o')
      $null=Add-UserAdaptationReceipt $Root $store observation_batch receipt-forget-batch (Get-UserAdaptationHash receipt-forget-payload 32) $from ([int]$store.revision) '' @($responseIdentity,$reasoningIdentity)
      Write-UserAdaptationJsonLockHeld $paths.storeV2 $store 30
    }|Out-Null
    @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).receipts|Where-Object{$_.kind-eq'observation_batch'}).Count | Should Be 1
    $preference=@((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile|Where-Object{$_.habitKey-eq'response_detail'-and$_.status-eq'active'})[0]
    $forgotten=Remove-UserAdaptationPreference -Root $Root -PreferenceId $preference.preferenceId -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int](Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).revision) -TransitionId receipt-forget-remove -Confirmed
    $forgotten.ok | Should Be $true
    @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).receipts|Where-Object{$_.kind-eq'observation_batch'}).Count | Should Be 0
  }

  It 'rejects freeform and unknown adaptation signals' {
    $workspaceKey = 'ws-ffffffffffffffffffffffff'
    Set-TestVerifiedOutcome $script:AdaptationWorkspace invalid-task $workspaceKey
    (Invoke-TestAdaptationObserver $script:AdaptationWorkspace invalid-task $workspaceKey @('response_detail=concise because it worked')).error | Should Be 'USER_ADAPTATION_OBSERVER_SIGNAL_INVALID'
    (Invoke-TestAdaptationObserver $script:AdaptationWorkspace invalid-task $workspaceKey @('personality=engineer')).error | Should Be 'USER_ADAPTATION_HABIT_KEY_INVALID'
    (Test-Path (Join-Path $script:AdaptationWorkspace 'user-adaptation\observations.json')) | Should Be $false
  }

  It 'fails observer writes closed on unmigrated V1 state' {
    $workspaceKey = 'ws-111111111111111111111111'
    $artifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $script:AdaptationWorkspace -TaskId unmigrated-task -WorkspaceKey $workspaceKey -Signals @('response_detail=concise')
    $result=Invoke-TestAdaptationObserver $script:AdaptationWorkspace unmigrated-task $workspaceKey @('response_detail=concise') Apply coding accepted_outcome '' '' @() $artifact.path
    $result.ok | Should Be $false
    $result.error | Should Be 'USER_ADAPTATION_OBSERVER_V2_REQUIRED'
    (Test-Path (Join-Path $script:AdaptationWorkspace 'user-adaptation\store.v2.json')) | Should Be $false
  }

  It 'keeps unmigrated V1 readable but freezes every public mutation entry point' {
    $paths=Get-UserAdaptationPaths $Root $script:AdaptationWorkspace;$defaults=New-UserAdaptationStoreDefaults;$now='2026-07-22T00:00:00Z'
    Write-TestAdaptationJson $paths.state ([pscustomobject]@{schema='super-brain.user-adaptation-state.v1';enabled=$true;updatedAt=$now;rawPromptStored=$false})
    Write-TestAdaptationJson $paths.observations $defaults.observations
    Write-TestAdaptationJson $paths.candidates $defaults.candidates
    Write-TestAdaptationJson $paths.profile $defaults.profile
    Write-TestAdaptationJson $paths.tombstones $defaults.tombstones
    (Get-UserAdaptationStatus $Root $script:AdaptationWorkspace).schema|Should Be 'super-brain.user-adaptation-status.v1'
    $before=@{};foreach($path in @($paths.state,$paths.observations,$paths.candidates,$paths.profile,$paths.tombstones)){$before[$path]=Get-SuperBrainFileSha256 $path}
    $errors=@()
    try{$null=Add-UserAdaptationObservation -Root $Root -HabitKey response_detail -Value concise -Source explicit_user -Scope global -WorkspaceRoot $script:AdaptationWorkspace}catch{$errors+=$_.Exception.Message}
    try{$null=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace}catch{$errors+=$_.Exception.Message}
    try{$null=Set-UserAdaptationEnabled -Root $Root -Enabled $false -WorkspaceRoot $script:AdaptationWorkspace}catch{$errors+=$_.Exception.Message}
    try{$null=Remove-UserAdaptationPreference -Root $Root -PreferenceId pref-v1-blocked -WorkspaceRoot $script:AdaptationWorkspace -Confirmed}catch{$errors+=$_.Exception.Message}
    $errors.Count|Should Be 4
    @($errors|Where-Object{$_-eq'USER_ADAPTATION_V2_MIGRATION_REQUIRED'}).Count|Should Be 4
    foreach($path in $before.Keys){(Get-SuperBrainFileSha256 $path)|Should Be $before[$path]}
    (Test-Path $paths.storeV2)|Should Be $false
  }

  It 'deduplicates repeated observations from the same verified task' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-222222222222222222222222'
    $artifact=Write-TestAdaptationVerificationArtifact -WorkspaceRoot $script:AdaptationWorkspace -TaskId duplicate-task -WorkspaceKey $workspaceKey -Signals @('response_detail=balanced')
    (Invoke-TestAdaptationObserver $script:AdaptationWorkspace duplicate-task $workspaceKey @('response_detail=balanced') Apply coding accepted_outcome '' '' @() $artifact.path).appliedCount | Should Be 1
    $duplicate = Invoke-TestAdaptationObserver $script:AdaptationWorkspace duplicate-task $workspaceKey @('response_detail=balanced') Apply coding accepted_outcome '' '' @() $artifact.path
    $duplicate.appliedCount | Should Be 0
    $duplicate.duplicateCount | Should Be 1
    (Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).observationCount | Should Be 1
  }

  It 'does not learn from an ungoverned task verification without a completed real-user outcome' {
    $stateRoot = Join-Path $TestDrive 'task-verification-adaptation'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-verification-adaptation'
    $workspaceKey = 'ws-333333333333333333333333'
    Write-TestAdaptationJson (Join-Path $workspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version='test';checkedAt='test'})
    Write-TestAdaptationJson (Join-Path $workspace 'last-hot-refresh.json') ([pscustomobject]@{ok=$true;checkedAt='test'})
    Write-TestAdaptationJson (Join-Path $workspace 'last-causal-change-review.json') ([pscustomobject]@{ok=$true;taskId=$taskId;gaps=@();expectedVsActual=[pscustomobject]@{decision='accepted'}})
    Write-TestAdaptationJson (Join-Path $workspace 'last-integration-contract-replay.json') ([pscustomobject]@{ok=$true;taskId=$taskId;unresolvedBehaviorMismatch=$false;mismatches=@()})
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TaskVerification -TaskId $taskId -WorkspaceKey $workspaceKey -Summary 'verified adaptation bridge' -Evidence 'focused integration test' -AdaptationSignals 'reasoning_style=evidence_first' -AdaptationContext coding -Json 2>$null)
      $LASTEXITCODE | Should Be 1
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.ok | Should Be $false
      $result.adaptationObservation.ok | Should Be $false
      $result.adaptationObservation.reason | Should Match 'USER_ADAPTATION_COMPLETED_TASK_REQUIRED|USER_ADAPTATION_VERIFIED_OUTCOME_REQUIRED'
      (Test-Path (Join-Path $workspace 'user-adaptation\store.v2.json')) | Should Be $false
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }

  It 'keeps adaptation at zero when a matching task still has pending work' {
    $stateRoot=Join-Path $TestDrive 'tv-pending';$workspace=Join-Path $stateRoot 'workspace';$taskId='tv-pending';$workspaceKey='ws-999999999999999999999999';$sessionKey='sid-9999999999999999'
    $null=Initialize-TestV2AdaptationStore $workspace
    Write-TestAdaptationJson (Join-Path $workspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version='test';checkedAt='test'})
    Write-TestAdaptationJson (Join-Path $workspace 'last-hot-refresh.json') ([pscustomobject]@{ok=$true;checkedAt='test'})
    Write-TestAdaptationJson (Join-Path $workspace 'last-causal-change-review.json') ([pscustomobject]@{ok=$true;taskId=$taskId;gaps=@();expectedVsActual=[pscustomobject]@{decision='accepted'}})
    Write-TestAdaptationJson (Join-Path $workspace 'last-integration-contract-replay.json') ([pscustomobject]@{ok=$true;taskId=$taskId;unresolvedBehaviorMismatch=$false;mismatches=@()})
    Write-TestAdaptationJson (Join-Path $workspace 'last-integration-parity-check.json') ([pscustomobject]@{ok=$true;taskId=$taskId;unresolvedIntegrationDrift=$false;drifts=@();moduleVerification=[pscustomobject]@{ok=$true};integrationVerification=[pscustomobject]@{ok=$true};userAcceptanceVerification=[pscustomobject]@{ok=$true;realUserPathVerification=$true}})
    $oldStateRoot=$env:SUPER_BRAIN_STATE_ROOT;$oldThreadId=$env:SUPER_BRAIN_LOCAL_SESSION_ID
    try{
      $env:SUPER_BRAIN_STATE_ROOT=$stateRoot;$env:SUPER_BRAIN_LOCAL_SESSION_ID=$sessionKey
      $null=& (Join-Path $Root 'scripts\checkpoint-writer.ps1') -Action Start -TaskId $taskId -TaskName 'Pending task' -WorkspaceKey $workspaceKey -SessionId $sessionKey -CurrentStep 'work remains' -PendingSteps 'unfinished implementation' -Json|ConvertFrom-Json
      $raw=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TaskVerification -TaskId $taskId -WorkspaceKey $workspaceKey -Summary 'verification cannot close pending task' -Evidence 'pending-work failure injection' -AdaptationSignals 'reasoning_style=evidence_first' -AdaptationContext coding -Json 2>$null)
      $LASTEXITCODE|Should Be 1
      $result=(($raw-join"`n")|ConvertFrom-Json)
      $result.completionOutcome.completed|Should Be $false
      $result.completionOutcome.reason|Should Be 'pending_work_preserved'
      $result.adaptationObservation.ok|Should Be $false
      $result.adaptationObservation.reason|Should Match 'USER_ADAPTATION_COMPLETED_TASK_REQUIRED'
      (Get-UserAdaptationStatus $Root $workspace).observationCount|Should Be 0
      @(Get-ChildItem -LiteralPath (Join-Path $workspace 'runtime-state\user-adaptation-verifications') -File -ErrorAction SilentlyContinue).Count|Should Be 0
    }finally{$env:SUPER_BRAIN_STATE_ROOT=$oldStateRoot;$env:SUPER_BRAIN_LOCAL_SESSION_ID=$oldThreadId}
  }

  # Retired P7 fixture retained as historical reference; H7 turn-runtime and
  # direct adaptation APIs are the current acceptance paths.
  It 'records a canonical V2 workflow measurement through task verification' -Skip {
    $stateRoot = Join-Path $TestDrive 'tv2'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'tv2-measure'
    $workspaceKey = 'ws-888888888888888888888888'
    $sessionKey = 'sid-8888888888888888'
    $null = Initialize-TestV2AdaptationStore $workspace
    Write-TestAdaptationJson (Join-Path $workspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version='test';checkedAt='test'})
    Write-TestAdaptationJson (Join-Path $workspace 'last-hot-refresh.json') ([pscustomobject]@{ok=$true;checkedAt='test'})
    Write-TestAdaptationJson (Join-Path $workspace 'last-causal-change-review.json') ([pscustomobject]@{ok=$true;taskId=$taskId;gaps=@();expectedVsActual=[pscustomobject]@{decision='accepted'}})
    Write-TestAdaptationJson (Join-Path $workspace 'last-integration-contract-replay.json') ([pscustomobject]@{ok=$true;taskId=$taskId;unresolvedBehaviorMismatch=$false;mismatches=@()})
    Write-TestAdaptationJson (Join-Path $workspace 'last-integration-parity-check.json') ([pscustomobject]@{ok=$true;taskId=$taskId;unresolvedIntegrationDrift=$false;drifts=@();moduleVerification=[pscustomobject]@{ok=$true;status='module verified'};integrationVerification=[pscustomobject]@{ok=$true;status='integration verified'};userAcceptanceVerification=[pscustomobject]@{ok=$true;status='real path verified';realUserPathVerification=$true}})
    $measurement = 'review_protocol=multi_pass;forwardPasses=3;reversePasses=2;riskFloor=structural'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldThreadId = $env:SUPER_BRAIN_LOCAL_SESSION_ID
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_LOCAL_SESSION_ID = $sessionKey
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $checkpointRaw=@(& (Join-Path $Root 'scripts\checkpoint-writer.ps1') -Action Start -TaskId $taskId -TaskName 'Verified review protocol' -WorkspaceKey $workspaceKey -SessionId $sessionKey -CurrentStep 'all protocol passes complete' -Json)
      $checkpoint=(($checkpointRaw-join"`n")|ConvertFrom-Json)
      $labels=@('Forward review pass alpha','Forward review pass beta','Forward review pass gamma','Reverse audit alpha','Reverse audit beta','Structural boundary verification')
      $contractArgs=@{Action='Set';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;FocusId='code-review';InstructionMode='continue';LatestUserInstruction='approve the complete review protocol';AssistantCommitment='complete every approved review pass';NextAction='complete verified protocol';CurrentPhase='verification';CurrentStep='all passes complete';CompletedSteps=$labels;PendingSteps=@();Constraints=@('structural risk is the minimum review boundary');AcceptanceCriteria=@('all review passes completed');EnableCanonicalPlan=$true;RequireStructuralGuards=$true;Source='UserAdaptation.Tests.ps1';NoExit=$true;Json=$true}
      $contractRaw=@(& (Join-Path $Root 'scripts\execution-contract.ps1') @contractArgs)
      $contract=(($contractRaw-join"`n")|ConvertFrom-Json)
      $contract.ok | Should Be $true
      $contract.canonicalPlan.orderConfidence | Should Be 'verified'
      $contract.needsReconciliation | Should Be $false
      $choicePrompt='For this task, use forward review 3 passes and reverse audit 2 passes; structural risk is the minimum boundary.'
      $choicePayload=([pscustomobject]@{session_id=$sessionKey;turn_id='turn-review-protocol-choice';prompt=$choicePrompt}|ConvertTo-Json -Compress)
      $hookRaw=@($choicePayload|& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE|Should Be 0
      $hookPointer=Get-Content -LiteralPath (Join-Path $workspace 'last-codex-user-prompt-hook.json') -Raw -Encoding UTF8|ConvertFrom-Json
      $hookTelemetry=Get-Content -LiteralPath (Join-Path $workspace (([string]$hookPointer.telemetryRelativePath)-replace'/','\')) -Raw -Encoding UTF8|ConvertFrom-Json
      $hookTelemetry.adaptationChoiceReceipt.ok|Should Be $true
      $hookTelemetry.adaptationChoiceReceipt.protocolRequested|Should Be $true
      $observedRaw=@(& (Join-Path $Root 'scripts\execution-contract.ps1') -Action Get -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $sessionKey -NoExit -Json)
      $observed=(($observedRaw-join"`n")|ConvertFrom-Json)
      $observed.needsReconciliation|Should Be $true
      $reconciledRaw=@(& (Join-Path $Root 'scripts\execution-contract.ps1') -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'code-review' -InstructionMode continue -LatestUserInstruction $choicePrompt -AssistantCommitment 'complete every approved review pass' -NextAction 'complete verified protocol' -CurrentPhase verification -CurrentStep 'all passes complete' -CompletedSteps $labels -PendingSteps @() -Constraints 'structural risk is the minimum review boundary' -AcceptanceCriteria 'all review passes completed' -ExpectedRevision ([int]$observed.revision) -ExpectedPlanFingerprint ([string]$observed.planReceipt.planFingerprint) -TransitionId 'accept-review-protocol-choice' -Source 'UserAdaptation.Tests.ps1' -NoExit -Json)
      $reconciled=(($reconciledRaw-join"`n")|ConvertFrom-Json)
      $reconciled.ok|Should Be $true
      $reconciled.taskInstanceId|Should Be $contract.taskInstanceId
      $confirmation=[pscustomobject]@{relativePath=[string]$hookTelemetry.adaptationChoiceReceipt.relativePath;sha256=[string]$hookTelemetry.adaptationChoiceReceipt.sha256}
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TaskVerification -TaskId $taskId -WorkspaceKey $workspaceKey -Summary 'verified V2 measurement bridge' -Evidence 'focused integration test' -AdaptationMeasurements $measurement -AdaptationContext review -AdaptationWorkflowKey code-review -AdaptationConfirmationReceiptPath $confirmation.relativePath -AdaptationConfirmationReceiptHash $confirmation.sha256 -Json 2>$null)
      if($LASTEXITCODE-ne0){throw ('TASK_VERIFICATION_DIAGNOSTIC '+($raw-join"`n"))}
      $LASTEXITCODE | Should Be 0
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.ok | Should Be $true
      $result.adaptationObservation.ok | Should Be $true
      $result.adaptationObservation.appliedCount | Should Be 1
      $observation = @((Get-UserAdaptationV2Store $Root $workspace).observations)[0]
      $observation.evidenceKind | Should Be 'workflow_measurement'
      $observation.producer | Should Be 'verified_task_protocol'
      $observation.parameters.forwardPasses | Should Be 3
      $observation.parameters.reversePasses | Should Be 2
      $observation.scopeKey | Should Be "$workspaceKey`:code-review"
      $observation.verificationHash | Should Be ([string]$result.adaptationObservation.verificationHash)
      (Test-Path (Join-Path $workspace 'runtime-state\user-adaptation-verifications')) | Should Be $true
      $canonicalVerificationPath=Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\task-verifications') $taskId '.json'
      $outcomePath=Join-Path $workspace 'runtime-state\verified-task-outcomes\tv2-measure.json'
      $lastVerificationPath=Join-Path $workspace 'last-task-verification.json'
      $canonicalHashBefore=Get-SuperBrainFileSha256 $canonicalVerificationPath;$outcomeHashBefore=Get-SuperBrainFileSha256 $outcomePath;$lastHashBefore=Get-SuperBrainFileSha256 $lastVerificationPath
      $exploitRaw=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TaskVerification -TaskId $taskId -WorkspaceKey $workspaceKey -Summary 'caller-only adaptation must be rejected' -Evidence 'no host confirmation receipt' -AdaptationSignals 'reasoning_style=evidence_first' -AdaptationContext review -AdaptationWorkflowKey code-review -Json 2>$null)
      $LASTEXITCODE|Should Be 0
      $exploit=(($exploitRaw-join"`n")|ConvertFrom-Json)
      $exploit.schema|Should Be 'super-brain.task-verification-replay-diagnostic.v1'
      $exploit.reason|Should Be 'completed_task_replay_withheld'
      $exploit.adaptationObservation.ok|Should Be $false
      $exploit.adaptationObservation.reason|Should Be 'USER_ADAPTATION_COMPLETED_TASK_REPLAY_WITHHELD'
      (Get-SuperBrainFileSha256 $canonicalVerificationPath)|Should Be $canonicalHashBefore
      (Get-SuperBrainFileSha256 $outcomePath)|Should Be $outcomeHashBefore
      (Get-SuperBrainFileSha256 $lastVerificationPath)|Should Be $lastHashBefore
      (Test-Path (Join-Path $workspace 'last-task-verification-replay.json'))|Should Be $true
      @((Get-UserAdaptationV2Store $Root $workspace).observations).Count|Should Be 1
    } finally {
      if($null-eq$oldStateRoot){Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_STATE_ROOT=$oldStateRoot}
      if($null-eq$oldThreadId){Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_LOCAL_SESSION_ID=$oldThreadId}
      if($null-eq$oldWorkspaceKey){Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_WORKSPACE_KEY=$oldWorkspaceKey}
    }
  }

  It 'reports bounded evolution and explanation as private local diagnostics, not improvement claims' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-evolutionaaaaaaaaaaaaaa'
    $sentinel = 'RAW-PROMPT-SENTINEL-EVOLUTION-DO-NOT-STORE'
    $revision = [int](Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).revision
    $observed = Add-UserAdaptationObservation -Root $Root -HabitKey reasoning_style -Value evidence_first -Signal Support -Source explicit_user -Scope project -ScopeKey $workspaceKey -Context review -TaskId evolution-explain-task -EvidenceRef $sentinel -WorkspaceRoot $script:AdaptationWorkspace -EvidenceKind durable_explicit -Producer trusted_direct_statement -ExpectedRevision $revision -TransitionId evolution-explain-observe
    $synthesized = Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int]$observed.revision) -TransitionId evolution-explain-synthesize
    $preference = @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile | Where-Object { $_.habitKey -eq 'reasoning_style' -and $_.status -eq 'active' })[0]

    $explain = Get-UserAdaptationExplainV2 -Root $Root -PreferenceId $preference.preferenceId -WorkspaceRoot $script:AdaptationWorkspace
    $evolution = Get-UserAdaptationEvolutionV2 -Root $Root -WorkspaceRoot $script:AdaptationWorkspace

    $synthesized.ok | Should Be $true
    $explain.ok | Should Be $true
    $explain.trustLevel | Should Be 'local_same_user_unattested'
    $explain.evaluation.status | Should Be 'not_scored'
    $explain.evaluation.improvementClaimAllowed | Should Be $false
    $explain.rawPromptStored | Should Be $false
    $evolution.trustLevel | Should Be 'local_same_user_unattested'
    $evolution.evaluation.status | Should Be 'not_scored'
    $evolution.evaluation.improvementClaimAllowed | Should Be $false
    $evolution.metrics.activationVelocity.status | Should Be 'not_scored'
    (($explain | ConvertTo-Json -Depth 20 -Compress).Contains($sentinel)) | Should Be $false
    (($evolution | ConvertTo-Json -Depth 20 -Compress).Contains($sentinel)) | Should Be $false
  }

  It 'redacts evolution coverage and metrics after a confirmed forget' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-redactaaaaaaaaaaaaaaaaa'
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace response_detail concise project $workspaceKey coding redact-seed
    $preference = @((Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace).profile | Where-Object { $_.habitKey -eq 'response_detail' -and $_.status -eq 'active' })[0]
    $forgotten = Remove-UserAdaptationPreference -Root $Root -PreferenceId $preference.preferenceId -WorkspaceRoot $script:AdaptationWorkspace -ExpectedRevision ([int](Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).revision) -TransitionId redact-forget -Confirmed
    $evolution = Get-UserAdaptationEvolutionV2 -Root $Root -WorkspaceRoot $script:AdaptationWorkspace

    $forgotten.ok | Should Be $true
    $evolution.history.coverage | Should Be 'redacted'
    $evolution.metrics.activationVelocity.status | Should Be 'not_scored'
    $evolution.metrics.activationVelocity.reasonCode | Should Be 'history_redacted'
    $evolution.evaluation.improvementClaimAllowed | Should Be $false
  }

  It 'bounds and chains lifecycle receipts without freeform data' {
    $null = Initialize-TestV2AdaptationStore $script:AdaptationWorkspace
    $workspaceKey = 'ws-chainaaaaaaaaaaaaaaaaaa'
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace speaking_style warm_direct project $workspaceKey coding chain-seed
    $store = Get-UserAdaptationV2Store $Root $script:AdaptationWorkspace
    $changes = @(1..9 | ForEach-Object {
      [pscustomobject]@{entityType='candidate';entityId=('candidate-' + ('{0:x16}' -f $_));fromStatus='';toStatus='staged';reasonCode='synthesis';scope='project';freeform='FREEFORM-LIFECYCLE-SENTINEL'}
    })
    $lastPersisted = [string]$store.receipts[-1].chainHash
    $receipt = Add-UserAdaptationReceipt $Root $store synthesis bounded-lifecycle-test (Get-UserAdaptationHash 'bounded-lifecycle-test' 32) ([int]$store.revision) ([int]$store.revision + 1) '' @() $changes

    @($receipt.lifecycleChanges).Count | Should Be 8
    $receipt.previousChainHash | Should Be $lastPersisted
    $receipt.chainHash | Should Match '^[a-f0-9]{64}$'
    $receipt.trustLevel | Should Be 'local_same_user_unattested'
    (($receipt | ConvertTo-Json -Depth 20 -Compress).Contains('FREEFORM-LIFECYCLE-SENTINEL')) | Should Be $false
    $previous = ''
    foreach ($persisted in @($store.receipts | Select-Object -First ($store.receipts.Count - 1))) {
      $persisted.chainHash | Should Match '^[a-f0-9]{64}$'
      $persisted.previousChainHash | Should Be $previous
      $previous = [string]$persisted.chainHash
    }
  }

  It 'uses matched experience only as a fixed advisory and leaves new reasoning available' {
    $stateRoot = Join-Path $TestDrive 'experience-advisory'
    $workspace = Join-Path $stateRoot 'workspace'
    $sentinel = 'FREEFORM-EXPERIENCE-EVIDENCE-SENTINEL'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'experience-index.md'), ("### cache-regression`n- Recall Query: ``cache regression```n- Evidence Paths: ``$sentinel``"), [Text.UTF8Encoding]::new($false))
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $matched = ((@(& $Preflight -Query 'fix cache regression' -Json) -join "`n") | ConvertFrom-Json)
      $experience = @($matched.cards | Where-Object { $_.kind -eq 'similar_experience' })[0]
      $unmatched = ((@(& $Preflight -Query 'design a new isolated workflow' -Json) -join "`n") | ConvertFrom-Json)

      $experience.lessonId | Should Be 'cache-regression'
      $experience.claim | Should Be 'A retained prior experience may be relevant. Treat it only as an advisory hypothesis; current independent evidence must confirm it before reuse.'
      $experience.source | Should Be 'experience-index retained lesson metadata'
      $experience.advisory | Should Be $true
      $experience.hard | Should Be $false
      $experience.requiresCurrentIndependentEvidence | Should Be $true
      $experience.reuseStatus | Should Be 'insufficient'
      (($matched | ConvertTo-Json -Depth 20 -Compress).Contains($sentinel)) | Should Be $false
      @($unmatched.cards | Where-Object { $_.kind -eq 'similar_experience' }).Count | Should Be 0
      @($unmatched.cards | Where-Object { $_.kind -eq 'cognitive_control' }).Count | Should BeGreaterThan 0
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }

  It 'stores a pitfall as scoped revalidation-bound advice instead of a hard rule' {
    $stateRoot = Join-Path $TestDrive 'pitfall-experience'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ExperienceWriter -Id 'forum-post-pitfall' -Title 'Forum submission screen context' -Kind pitfall -Triggers @('forum post','textbox') -Scope project -RootCause 'A submission form was confused with the forum home screen.' -PreventionGate @('Verify the current route and screen state before inferring control availability.') -Evidence @('verification:forum-screen-context') -RevalidateAfterDays 0 -Json 2>$null)
      $result = ($raw -join "`n") | ConvertFrom-Json
      $recordPath = Join-Path $stateRoot 'workspace\experiences\forum-post-pitfall.json'
      $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $preflight = ((@(& $Preflight -Query 'debug forum post textbox availability' -Json) -join "`n") | ConvertFrom-Json)
      $pitfall = @($preflight.cards | Where-Object { $_.kind -eq 'known_pitfall' })[0]

      $result.ok | Should Be $true
      $result.kind | Should Be 'pitfall'
      $record.schema | Should Be 'super-brain.experience.v2'
      $record.kind | Should Be 'pitfall'
      $record.rootCause | Should Be 'A submission form was confused with the forum home screen.'
      @($record.preventionGates).Count | Should Be 1
      $record.revalidation.required | Should Be $true
      $pitfall.lessonId | Should Be 'forum-post-pitfall'
      $pitfall.advisory | Should Be $true
      $pitfall.hard | Should Be $false
      $pitfall.requiresCurrentIndependentEvidence | Should Be $true
      $pitfall.revalidationStatus | Should Be 'revalidation_due'
      $pitfall.experienceScope | Should Be 'project'
      (($preflight | ConvertTo-Json -Depth 20 -Compress).Contains('verification:forum-screen-context')) | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }
}
