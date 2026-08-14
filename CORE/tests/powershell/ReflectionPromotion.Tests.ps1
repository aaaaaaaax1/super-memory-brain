$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\reflection-promotion.ps1'
. (Join-Path $root 'scripts\common.ps1')
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Write-ReflectionJson([string]$Path, $Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Invoke-Reflection([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; text=$text; value=$(if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}) }
}

function New-Correction([string]$Id, [string]$Status = 'pending_verification', [string]$WorkspaceKey = 'ws-test') {
  return [pscustomobject]@{ schema='super-brain.correction-candidate.v1'; candidateId=$Id; capturedAt='2026-07-16 00:00:00'; promptHash='abcdef123456'; promptLength=38; signals=@('strong_correction'); workspaceKey=$WorkspaceKey; status=$Status; rawPromptStored=$false; durablePromotionAllowed=$false }
}

function Write-CurrentVerifiedOutcome([string]$Workspace, [string]$TaskId, [string]$CandidateId, [string]$WorkspaceKey) {
  $ownerSessionKey = 'sid-reflection-evidence'
  $artifactBinding = New-SuperBrainEvidenceBinding -TaskId $TaskId -WorkspaceKey $WorkspaceKey -OwnerSessionKey $ownerSessionKey -Root $root
  $verificationPath = Get-SuperBrainCanonicalTaskPath (Join-Path $Workspace 'runtime-state\task-verifications') $TaskId '.json'
  Write-ReflectionJson $verificationPath ([pscustomobject]@{ schema='super-brain.task-verification.v1';ok=$true;taskId=$TaskId;workspaceKey=$WorkspaceKey;evidenceBinding=$artifactBinding })
  $completionBinding = [pscustomobject]@{
    schema=[string]$artifactBinding.schema;packageVersion=[string]$artifactBinding.packageVersion;gitTreeHash=[string]$artifactBinding.gitTreeHash;treeAlgorithm=[string]$artifactBinding.treeAlgorithm;gitHeadTreeHash=[string]$artifactBinding.gitHeadTreeHash
    taskId=[string]$artifactBinding.taskId;workspaceKey=[string]$artifactBinding.workspaceKey;ownerSessionKey=[string]$artifactBinding.ownerSessionKey;artifactHash=(Get-FileHash -LiteralPath $verificationPath -Algorithm SHA256).Hash.ToLowerInvariant();artifactKind='task_verification'
  }
  Write-ReflectionJson (Join-Path $Workspace "runtime-state\checkpoints\completed\$TaskId.json") ([pscustomobject]@{ schema='super-brain.checkpoint.v1';taskId=$TaskId;status='completed';source='task-verification.ps1' })
  $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $Workspace 'task-state-store\projections') $TaskId '.json'
  Write-ReflectionJson $projectionPath ([pscustomobject]@{ schema='super-brain.task-state-projection.v2';taskId=$TaskId;revision=1;lifecycle=[pscustomobject]@{status='completed';ownerSessionKey=$ownerSessionKey;evidenceBinding=$completionBinding} })
  $outcomePath = Join-Path $Workspace "runtime-state\verified-task-outcomes\$TaskId.json"
  Write-ReflectionJson $outcomePath ([pscustomobject]@{
    schema='super-brain.verified-task-outcome.v1';recordId=('verified-task-' + $TaskId);taskId=$TaskId;workspaceKey=$WorkspaceKey;packageVersion=[string]$manifest.version;recordedAt=(Get-Date).ToString('o');source='task-verification.ps1';correctionCandidateId=$CandidateId
    verification=[pscustomobject]@{ok=$true;taskScopedGuardOk=$true;realUserPathVerified=$true;completedCheckpointVerified=$true;packageVerificationOk=$true;hotRefreshOk=$true}
    classification=[pscustomobject]@{verifiedRealWorldTask=$true;verifiedAutonomyScenario=$false};evidenceBinding=$completionBinding;evidenceRefs=@('task-verification.ps1');privacy=[pscustomobject]@{rawPromptStored=$false;rawSummaryStored=$false}
  })
  return $outcomePath
}

Describe 'ReflectionPromotion correction lifecycle' {
  It 'keeps rule and skill candidates blocked without an explicit governed proposal path' {
    $text = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    $text.Contains('rule_or_skill_approval_required') | Should Be $true
    $text.Contains('requiresApproval') | Should Be $true
    $text.Contains('-Text $candidate.summary') | Should Be $false
    $text.Contains('skill_evolution_stage_failed') | Should Be $true
  }

  It 'stages reflective memory candidates for controlled queue adoption without writing durable memory' {
    $workspace = Join-Path $TestDrive 'controlled-reflection-stage'
    $result = Invoke-Reflection @(
      '-Mode','Apply','-TriggerType','completed_fix',
      '-Summary','A uniquely scoped verified user-path repair keeps reflective learning staged until current task evidence is bound.',
      '-Evidence','verification:controlled-reflection-stage',
      '-WorkspaceRoot',$workspace,'-AllowDuplicate','-Json'
    )
    $stored = @(
      Get-ChildItem -LiteralPath (Join-Path $workspace 'reflection\candidates') -Filter '*.json' -File |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } |
        Where-Object { $_.target -in @('experience','memory') }
    )
    $text = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

    $result.exitCode | Should Be 0
    $stored.Count | Should BeGreaterThan 0
    @($stored | Where-Object {
      [string]$_.lifecycle.status -eq 'staged' -and
      [string]$_.lifecycle.reason -eq 'controlled_queue_adoption_required' -and
      $_.promotion.applied -eq $false -and
      $_.promotion.requiresControlledAdoption -eq $true
    }).Count | Should BeGreaterThan 0
    $text.Contains('Invoke-ChildJson (Join-Path $PSScriptRoot ''learn-memory.ps1'') $args') | Should Be $false
  }

  It 'moves a linked pending correction to analyzed only with a compact explicit summary' {
    $workspace = Join-Path $TestDrive 'analyze'
    $id = 'correction-abcdef123456'
    $candidatePath = Join-Path $workspace "reflection\correction-candidates\$id.json"
    Write-ReflectionJson $candidatePath (New-Correction $id)
    $summary = 'The verified fix binds the exact requested skill before overlapping defaults and keeps raw prompts out.'

    $result = Invoke-Reflection @('-Mode','Analyze','-TriggerType','user_correction','-Summary',$summary,'-Evidence',"correctionCandidate=$id",'-WorkspaceRoot',$workspace,'-Json')
    $result.exitCode | Should Be 0
    $candidate = Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $candidate.status | Should Be 'analyzed'
    $candidate.analysisSummary | Should Be $summary
    $candidate.analysisSummaryHash.Length | Should Be 24
    $candidate.rawPromptStored | Should Be $false
    $candidate.durablePromotionAllowed | Should Be $false
    $candidate.regressionCapture.ok | Should Be $true
    $candidate.regressionCapture.id | Should Not BeNullOrEmpty
    $candidate.regressionCapture.rawPromptStored | Should Be $false
    $candidate.regressionCapture.rawSummaryStored | Should Be $false
    $result.value.correctionLifecycle.analyzed | Should Be 1
    $result.value.linkedCorrectionCandidate.status | Should Be 'analyzed'
  }

  It 'classifies corrections by a compact problem key so different lessons are not merged into one generic reminder' {
    $workspace = Join-Path $TestDrive 'classified-corrections'
    $workspaceKey = 'ws-333333333333333333333333'
    $experienceId = 'correction-classified-experience'
    $ruleId = 'correction-classified-rule'
    $experiencePath = Join-Path $workspace "reflection\correction-candidates\$experienceId.json"
    $rulePath = Join-Path $workspace "reflection\correction-candidates\$ruleId.json"
    Write-ReflectionJson $experiencePath (New-Correction $experienceId 'pending_verification' $workspaceKey)
    Write-ReflectionJson $rulePath (New-Correction $ruleId 'pending_verification' $workspaceKey)

    $experience = Invoke-Reflection @('-Mode','Analyze','-TriggerType','user_correction','-LearningClass','experience','-LearningKey','cross-session-intent-rebind','-Summary','The verified continuation keeps the original task intent and return point while changing only the owning session.','-Evidence',"correctionCandidate=$experienceId",'-WorkspaceRoot',$workspace,'-Json')
    $rule = Invoke-Reflection @('-Mode','Analyze','-TriggerType','user_correction','-LearningClass','system_rule','-LearningKey','user-correction-learning-admission','-Summary','A direct user correction must be classified, deduplicated, verified, and then routed into the correct governed learning path.','-Evidence',"correctionCandidate=$ruleId",'-WorkspaceRoot',$workspace,'-Json')

    $storedExperience = Get-Content -LiteralPath $experiencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $storedRule = Get-Content -LiteralPath $rulePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $learningCandidates = @(Get-ChildItem -LiteralPath (Join-Path $workspace 'reflection\candidates') -Filter '*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })

    $experience.exitCode | Should Be 0
    $rule.exitCode | Should Be 0
    $storedExperience.learningClassification.primaryClass | Should Be 'experience'
    $storedExperience.learningClassification.learningKey | Should Be 'cross-session-intent-rebind'
    $storedRule.learningClassification.primaryClass | Should Be 'system_rule'
    $storedRule.learningClassification.learningKey | Should Be 'user-correction-learning-admission'
    @($learningCandidates | Where-Object { $_.problemKey -eq 'cross-session-intent-rebind' -and $_.target -eq 'experience' }).Count | Should Be 1
    @($learningCandidates | Where-Object { $_.problemKey -eq 'user-correction-learning-admission' -and $_.target -eq 'skill_evolution' }).Count | Should Be 1

    Write-CurrentVerifiedOutcome $workspace 'task-classified-experience' $experienceId $workspaceKey | Out-Null
    $closed = Invoke-Reflection @('-Mode','Apply','-TriggerType','user_correction','-LearningClass','experience','-LearningKey','cross-session-intent-rebind','-Summary','The verified continuation keeps the original task intent and return point while changing only the owning session.','-Evidence',"correctionCandidate=$experienceId",'-WorkspaceRoot',$workspace,'-Json')
    $closedCandidate = Get-Content -LiteralPath $experiencePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $closed.exitCode | Should Be 0
    $closedCandidate.status | Should Be 'closed'
    $closed.value.correctionAdaptation.reason | Should Be 'verified_non_preference_correction_learning_closed'
  }

  It 'rejects an unverified short summary and leaves the correction pending' {
    $workspace = Join-Path $TestDrive 'short'
    $id = 'correction-123456abcdef'
    $candidatePath = Join-Path $workspace "reflection\correction-candidates\$id.json"
    Write-ReflectionJson $candidatePath (New-Correction $id)

    $result = Invoke-Reflection @('-Mode','Analyze','-TriggerType','user_correction','-Summary','too short','-Evidence',"correctionCandidate=$id",'-WorkspaceRoot',$workspace,'-Json')
    $result.exitCode | Should Not Be 0
    (Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should Be 'pending_verification'
  }

  It 'captures one scrubbed, deduplicated regression failure without proposing a rule or skill change' {
    $workspace = Join-Path $TestDrive 'regression-capture'
    $id = 'correction-regression-sample'
    $candidatePath = Join-Path $workspace "reflection\correction-candidates\$id.json"
    $candidate = New-Correction $id
    $candidate.signals = @('context_dependency_missed')
    $candidate | Add-Member -NotePropertyName taskId -NotePropertyValue 'task-regression-sample' -Force
    Write-ReflectionJson $candidatePath $candidate
    $summary = 'The verified repair restores current scoped context before a dependent action and blocks inferred defaults.'

    $first = Invoke-Reflection @('-Mode','Analyze','-TriggerType','user_correction','-Summary',$summary,'-Evidence',"correctionCandidate=$id",'-WorkspaceRoot',$workspace,'-Json')
    $first.exitCode | Should Be 0
    $second = Invoke-Reflection @('-Mode','Analyze','-TriggerType','user_correction','-Summary',$summary,'-Evidence',"correctionCandidate=$id",'-WorkspaceRoot',$workspace,'-Json')
    $second.exitCode | Should Be 0

    $stored = Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $stored.regressionCapture.ok | Should Be $true
    $stored.regressionCapture.reused | Should Be $true
    $failures = @(Get-ChildItem -LiteralPath (Join-Path $workspace 'skill-evolution\failures') -Filter '*.json' -File)
    $failures.Count | Should Be 1
    $failureText = Get-Content -LiteralPath $failures[0].FullName -Raw -Encoding UTF8
    $failureText.Contains($summary) | Should Be $false
    $failureText.Contains('correction-regression-sample') | Should Be $true
    @(Get-ChildItem -LiteralPath (Join-Path $workspace 'skill-evolution\proposals') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count | Should Be 0
  }

  It 'rejects secret-like values and machine paths before persisting a correction summary' {
    $workspace = Join-Path $TestDrive 'privacy'
    $id = 'correction-private-summary'
    $candidatePath = Join-Path $workspace "reflection\correction-candidates\$id.json"
    Write-ReflectionJson $candidatePath (New-Correction $id)
    $samples = @(
      'The verified correction used sk-1234567890abcdefghijkl and must be retained for future work.',
      'The verified correction is stored at C:\Users\PrivateName\project\result.json for later reuse.'
    )
    foreach($summary in $samples){
      $result=Invoke-Reflection @('-Mode','Analyze','-TriggerType','user_correction','-Summary',$summary,'-Evidence',"correctionCandidate=$id",'-WorkspaceRoot',$workspace,'-Json')
      $result.exitCode|Should Not Be 0
      (Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8|ConvertFrom-Json).status|Should Be 'pending_verification'
    }
  }

  It 'requires a current ledger-valid outcome before a correction can enter closing' {
    $workspace = Join-Path $TestDrive 'ledger-current-outcome'
    $workspaceKey = 'ws-111111111111111111111111'
    $id = 'correction-ledger-current'
    $taskId = 'task-reflection-current'
    $candidatePath = Join-Path $workspace "reflection\correction-candidates\$id.json"
    Write-ReflectionJson $candidatePath (New-Correction $id 'analyzed' $workspaceKey)
    Write-CurrentVerifiedOutcome $workspace $taskId $id $workspaceKey | Out-Null

    $result = Invoke-Reflection @('-Mode','Apply','-TriggerType','user_correction','-Summary','The verified correction has a current task-bound evidence chain before durable promotion.','-Evidence',"correctionCandidate=$id",'-WorkspaceRoot',$workspace,'-Json')
    $stored = Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $result.exitCode | Should Not Be 0
    $stored.status | Should Be 'closing'
    $stored.autonomyEvidenceLink.eligible | Should Be $true
    $stored.autonomyEvidenceLink.taskId | Should Be $taskId
  }

  It 'rejects a stale source-tree outcome before correction closure' {
    $workspace = Join-Path $TestDrive 'ledger-stale-outcome'
    $workspaceKey = 'ws-222222222222222222222222'
    $id = 'correction-ledger-stale'
    $taskId = 'task-reflection-stale'
    $candidatePath = Join-Path $workspace "reflection\correction-candidates\$id.json"
    Write-ReflectionJson $candidatePath (New-Correction $id 'analyzed' $workspaceKey)
    $outcomePath = Write-CurrentVerifiedOutcome $workspace $taskId $id $workspaceKey
    $outcome = Get-Content -LiteralPath $outcomePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $outcome.evidenceBinding.gitTreeHash = ('0' * 64)
    Write-ReflectionJson $outcomePath $outcome

    $result = Invoke-Reflection @('-Mode','Apply','-TriggerType','user_correction','-Summary','The correction must reject stale source-tree evidence before durable promotion.','-Evidence',"correctionCandidate=$id",'-WorkspaceRoot',$workspace,'-Json')
    $stored = Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $result.exitCode | Should Not Be 0
    $stored.status | Should Be 'analyzed'
    $result.value.correctionAdaptation.reason | Should Be 'verified_correction_outcome_required'
  }

  It 'reports pending analyzed closing and closed correction counts without reading prompt bodies' {
    $workspace = Join-Path $TestDrive 'list'
    $rootPath = Join-Path $workspace 'reflection\correction-candidates'
    Write-ReflectionJson (Join-Path $rootPath 'correction-pending.json') (New-Correction 'correction-pending')
    Write-ReflectionJson (Join-Path $rootPath 'correction-analyzed.json') (New-Correction 'correction-analyzed' 'analyzed')
    Write-ReflectionJson (Join-Path $rootPath 'correction-closing.json') (New-Correction 'correction-closing' 'closing')
    Write-ReflectionJson (Join-Path $rootPath 'correction-closed.json') (New-Correction 'correction-closed' 'closed')

    $result = Invoke-Reflection @('-Mode','List','-WorkspaceRoot',$workspace,'-Json')
    $result.exitCode | Should Be 0
    $result.value.correctionLifecycle.pending | Should Be 1
    $result.value.correctionLifecycle.analyzed | Should Be 1
    $result.value.correctionLifecycle.closing | Should Be 1
    $result.value.correctionLifecycle.closed | Should Be 1
    $result.value.rawPromptStored | Should Be $false
  }
}
