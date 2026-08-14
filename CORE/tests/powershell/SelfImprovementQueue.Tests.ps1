$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$queueScript = Join-Path $root 'scripts\self-improvement-queue.ps1'
$reflectionScript = Join-Path $root 'scripts\reflection-promotion.ps1'
$script:originalTreeCacheMode = [Environment]::GetEnvironmentVariable('SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_MODE','Process')
$script:originalTreeCachePath = [Environment]::GetEnvironmentVariable('SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_CACHE','Process')
$script:originalTreeCacheToken = [Environment]::GetEnvironmentVariable('SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_TOKEN','Process')
$script:treeCacheDirectory = ''

function Write-QueueTestJson([string]$Path, $Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
}

function Invoke-TestScriptProcess([string]$ScriptPath,[string[]]$Arguments) {
  # Several cases deliberately exercise a non-zero child exit.  Capture that
  # exit as test data even when a caller runs Pester with ErrorActionPreference=Stop.
  $previousErrorActionPreference = $ErrorActionPreference
  $hasNativeErrorPreference = Test-Path -LiteralPath 'Variable:\PSNativeCommandUseErrorActionPreference'
  if ($hasNativeErrorPreference) { $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference }
  try {
    $ErrorActionPreference = 'Continue'
    if ($hasNativeErrorPreference) { $PSNativeCommandUseErrorActionPreference = $false }
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($hasNativeErrorPreference) { $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference }
    $ErrorActionPreference = $previousErrorActionPreference
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$exitCode; text=$text; value=$(if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}) }
}

function Invoke-QueueTest([string[]]$Arguments) {
  return Invoke-TestScriptProcess $queueScript $Arguments
}

function Invoke-ReflectionTest([string[]]$Arguments) {
  return Invoke-TestScriptProcess $reflectionScript $Arguments
}

function New-QueueCandidate([string]$Id,[string]$Kind,[string]$Title,[string]$SeenAt,[int]$SeenCount=1,[string]$Priority='medium',[string]$Status='candidate',[bool]$AutoResolutionEligible=$false,[string]$RiskLevel='medium',[string]$ChangeClass='governed_change') {
  return [pscustomobject]@{
    id=$Id;kind=$Kind;title=$Title;status=$Status;priority=$Priority;problem='problem';expected='expected';evidence=@($Id);source='test';createdAt=$SeenAt;lastSeenAt=$SeenAt;seenCount=$SeenCount
    proposalLinks=@();verificationReceipts=@();autoResolutionEligible=$AutoResolutionEligible;riskLevel=$RiskLevel;changeClass=$ChangeClass
  }
}

function Write-LearningReceipt([string]$Workspace,[string]$ReceiptId,[string]$TaskId,[string]$WorkspaceKey) {
  . (Join-Path $root 'scripts\common.ps1')
  $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $tree = Get-SuperBrainSourceTreeBinding $root
  $receiptRoot = Join-Path $Workspace 'runtime-state\learning-verification-receipts'
  $path = Join-Path $receiptRoot ($ReceiptId + '.json')
  Write-QueueTestJson $path ([pscustomobject]@{
    schema='super-brain.learning-verification-receipt.v1';receiptId=$ReceiptId;taskId=$TaskId;workspaceKey=$WorkspaceKey;ownerSessionKey='sid-learning-test';packageVersion=[string]$manifest.version
    verificationArtifactHash=(('a' * 64) -join '');completionTransactionId=('complete-' + $TaskId)
    evidenceBinding=[pscustomobject]@{schema='super-brain.completion-evidence-binding.v1';packageVersion=[string]$manifest.version;gitTreeHash=[string]$tree.gitTreeHash;gitHeadTreeHash=[string]$tree.gitHeadTreeHash;treeAlgorithm=[string]$tree.treeAlgorithm;taskId=$TaskId;workspaceKey=$WorkspaceKey;ownerSessionKey='sid-learning-test';artifactHash=(('a' * 64) -join '');artifactKind='task_verification'}
    checks=[pscustomobject]@{taskVerification=$true;taskScopedGuard=$true;completedCheckpoint=$true;evidenceBindingCurrent=$true}
    privacy=[pscustomobject]@{rawPromptStored=$false;rawSummaryStored=$false;rawTranscriptStored=$false}
  })
  return [pscustomobject]@{ path=$path; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Write-ReflectionCandidateFixture([string]$Workspace,[string]$CandidateId='learn-fixture-controlled-memory-001') {
  $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $path = Join-Path $Workspace ('reflection\candidates\' + $CandidateId + '.json')
  $candidate = [pscustomobject]@{
    id=$CandidateId; familyKey='learning-fixture-controlled-memory-family'; sampleId='sample-fixture-controlled-memory-001'
    target='experience'; title='Verified fix should become reusable experience when scoped and evidenced'
    summary='A scoped verified repair preserves current task evidence before promotion and records a compact reusable lesson.'
    triggerType='completed_fix'; scope='super-memory-brain'; confidence=0.78
    evidence=@('verification:controlled-memory-real-path'); reason='Verified outcomes can be promoted into experience for future similar tasks.'
    problemKey=''; reusable=$true; privacyHit=$false
    duplicateCheck=[pscustomobject]@{checked=$true;possibleDuplicate=$false;source='test-fixture'}
    qualityCheck=[pscustomobject]@{hasEvidence=$true;aboveThreshold=$true;notNoise=$true}
    promotion=[pscustomobject]@{wouldWrite=$false;requiresApproval=$false;applied=$false;staged=$true;proposalId='';command='self-improvement-queue.ps1 controlled adoption path; task-bound validation and receipt required before durable memory write';requiresControlledAdoption=$true}
    lifecycle=[pscustomobject]@{status='staged';reason='controlled_queue_adoption_required';firstSeenAt=$now;lastSeenAt=$now;seenCount=1}
    scopeGate=[pscustomobject]@{checked=$true;ok=$true;gaps=0;source='lesson-scope-gate.ps1'}
  }
  Write-QueueTestJson $path $candidate
  return [pscustomobject]@{path=$path;candidate=$candidate}
}

function Initialize-IsolatedQueueMemory([string]$StateRoot) {
  $memoryRoot = Join-Path $StateRoot 'shared'
  $scriptRoot = Join-Path $root 'vendor\NexSandglass-Agent-DedicatedMemory'
  if (-not (Test-Path -LiteralPath (Join-Path $scriptRoot 'sandglass_log.py') -PathType Leaf)) { throw 'ISOLATED_MEMORY_RUNTIME_COPY_INCOMPLETE: sandglass_log.py is required by write-memory.ps1.' }
  [IO.File]::WriteAllText((Join-Path $memoryRoot 'sandglass.txt'), '', [Text.UTF8Encoding]::new($false))
  . (Join-Path $root 'scripts\common.ps1')
  [void](Write-SuperBrainSharingPolicy -Root $root -Mode 'shared' -ActiveRoot $memoryRoot)
  return $memoryRoot
}

function Get-IsolatedMemoryLineCount([string]$MemoryRoot) {
  return @(
    Get-Content -LiteralPath (Join-Path $MemoryRoot 'sandglass.txt') -Encoding UTF8 |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
  ).Count
}

function Write-SkillEvolutionProposal([string]$Workspace,[string]$ProposalId,[string]$Status,[string]$Fingerprint='proposal-fingerprint-001') {
  $path = Join-Path $Workspace ('skill-evolution\proposals\' + $ProposalId + '.json')
  $validation = if ($Status -eq 'validated') {
    [pscustomobject]@{contractVersion='v2';status='sealed-validated';sealedReplay=$true;sealedHoldout=$true;noConsumedHoldoutReuse=$true;overfitGuardPassed=$true;artifactSha256=(('b' * 64) -join '');rawPromptStored=$false}
  } else {
    [pscustomobject]@{contractVersion='pending';status='pending';sealedReplay=$false;sealedHoldout=$false;noConsumedHoldoutReuse=$false;overfitGuardPassed=$false;artifactSha256='';rawPromptStored=$false}
  }
  Write-QueueTestJson $path ([pscustomobject]@{
    id=$ProposalId;status=$Status;title='Phase 6 bounded proposal';affected='runtime/phase6_memory_eval.py';proposal='Use a separate replay artifact before changing any rule.';evidenceFingerprint=$Fingerprint;source='evaluation-learning-bridge.ps1';validation=$validation
  })
  return $path
}

function Write-LearningEffectArtifact(
  [string]$Workspace,
  [string]$ProposalId,
  [string]$Fingerprint='proposal-fingerprint-001',
  [string]$TaskId='task-effect-default-001',
  [string]$WorkspaceKey='ws-effect-default-001',
  [string]$OwnerSessionKey='sid-learning-test',
  [int]$BaselinePassCount=3,
  [int]$TreatmentPassCount=4
) {
  . (Join-Path $root 'scripts\common.ps1')
  $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $tree = Get-SuperBrainSourceTreeBinding $root
  $path = Join-Path $Workspace ('runtime-state\learning-effect-artifacts\' + $ProposalId + '-effect.json')
  Write-QueueTestJson $path ([pscustomobject]@{
    schema='super-brain.learning-effect-artifact.v2';proposalId=$ProposalId;evidenceFingerprint=$Fingerprint;packageVersion=[string]$manifest.version
    scopeBinding=[pscustomobject]@{schema='super-brain.learning-effect-scope-binding.v1';packageVersion=[string]$manifest.version;gitTreeHash=[string]$tree.gitTreeHash;gitHeadTreeHash=[string]$tree.gitHeadTreeHash;treeAlgorithm=[string]$tree.treeAlgorithm;taskId=$TaskId;workspaceKey=$WorkspaceKey;ownerSessionKey=$OwnerSessionKey}
    baseline=[pscustomobject]@{metricId='sealed_holdout_pass_rate';scenarioFamilyHash=(('f' * 64) -join '');sampleCount=4;passCount=$BaselinePassCount;passRate=([double]$BaselinePassCount / 4)}
    treatment=[pscustomobject]@{metricId='sealed_holdout_pass_rate';scenarioFamilyHash=(('f' * 64) -join '');sampleCount=4;passCount=$TreatmentPassCount;passRate=([double]$TreatmentPassCount / 4)}
    checks=[pscustomobject]@{comparableScenario=$true;independentHoldout=$true;regressionFree=$true;overfitGuardPassed=$true}
    privacy=[pscustomobject]@{rawPromptStored=$false;rawTranscriptStored=$false;rawCasePayloadStored=$false}
  })
  return $path
}

Describe 'Self improvement bounded lifecycle' {
  BeforeAll {
    . (Join-Path $root 'scripts\common.ps1')
    $binding = Get-SuperBrainSourceTreeBinding $root
    $script:treeCacheDirectory = Join-Path ([IO.Path]::GetTempPath()) ('super-brain-test-tree-cache-' + [Guid]::NewGuid().ToString('N'))
    $cachePath = Join-Path $script:treeCacheDirectory 'source-tree-binding.json'
    $token = [Guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Force -Path $script:treeCacheDirectory | Out-Null
    Write-QueueTestJson $cachePath ([pscustomobject]@{
      schema='super-brain.test-source-tree-binding-cache.v1';packageRoot=[IO.Path]::GetFullPath($root);token=$token;binding=$binding
    })
    [Environment]::SetEnvironmentVariable('SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_MODE','1','Process')
    [Environment]::SetEnvironmentVariable('SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_CACHE',$cachePath,'Process')
    [Environment]::SetEnvironmentVariable('SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_TOKEN',$token,'Process')
  }

  AfterAll {
    [Environment]::SetEnvironmentVariable('SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_MODE',$script:originalTreeCacheMode,'Process')
    [Environment]::SetEnvironmentVariable('SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_CACHE',$script:originalTreeCachePath,'Process')
    [Environment]::SetEnvironmentVariable('SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_TOKEN',$script:originalTreeCacheToken,'Process')
    if (-not [string]::IsNullOrWhiteSpace($script:treeCacheDirectory) -and (Test-Path -LiteralPath $script:treeCacheDirectory)) {
      Remove-Item -LiteralPath $script:treeCacheDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps Status read-only and does not create state' {
    $workspace = Join-Path $TestDrive 'status-empty'
    $before = @(Get-ChildItem -Recurse -Force -LiteralPath $workspace -ErrorAction SilentlyContinue).Count
    $result = Invoke-QueueTest @('-Action','Status','-WorkspaceRoot',$workspace,'-Json')
    $after = @(Get-ChildItem -Recurse -Force -LiteralPath $workspace -ErrorAction SilentlyContinue).Count

    $result.exitCode | Should Be 0
    $result.value.action | Should Be 'Status'
    $result.value.sideEffectFree | Should Be $true
    $result.value.total | Should Be 0
    $after | Should Be $before
    Test-Path -LiteralPath $workspace | Should Be $false
    Test-Path (Join-Path $workspace 'self-improvement-queue.json') | Should Be $false
    Test-Path (Join-Path $workspace 'last-self-improvement-queue.json') | Should Be $false
  }

  It 'keeps reflection Preview read-only' {
    $workspace = Join-Path $TestDrive 'reflection-preview'
    $candidateRoot = Join-Path $workspace 'reflection\candidates'
    $result = Invoke-ReflectionTest @('-Mode','Preview','-TriggerType','completed_fix','-Summary','A verified reusable fix with bounded evidence and scope.','-Evidence','targeted test passed','-WorkspaceRoot',$workspace,'-Json')

    $result.exitCode | Should Be 0
    @($result.value.candidates).Count -gt 0 | Should Be $true
    @(Get-ChildItem -LiteralPath $candidateRoot -File -ErrorAction SilentlyContinue).Count | Should Be 0
    Test-Path (Join-Path $workspace 'last-reflection-promotion.json') | Should Be $false
    Test-Path (Join-Path $workspace 'last-lesson-scope-gate.json') | Should Be $false
  }

  It 'imports a staged reflection candidate into the governed queue by stable candidate id' {
    $workspace = Join-Path $TestDrive 'staged-reflection-import'
    $reflection = Invoke-ReflectionTest @(
      '-Mode','Apply','-TriggerType','completed_fix',
      '-Summary','A unique verified user-path repair remains staged for current task-bound controlled learning.',
      '-Evidence','verification:staged-reflection-import',
      '-WorkspaceRoot',$workspace,'-AllowDuplicate','-Json'
    )
    $stored = @(
      Get-ChildItem -LiteralPath (Join-Path $workspace 'reflection\candidates') -Filter '*.json' -File |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } |
        Where-Object { [string]$_.lifecycle.status -eq 'staged' -and $_.promotion.requiresControlledAdoption -eq $true }
    )
    $collected = Invoke-QueueTest @('-Action','Collect','-WorkspaceRoot',$workspace,'-Json')
    $queue = Get-Content -LiteralPath (Join-Path $workspace 'self-improvement-queue.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    $reflection.exitCode | Should Be 0
    $stored.Count | Should BeGreaterThan 0
    $collected.exitCode | Should Be 0
    @($queue.items | Where-Object {
      @($_.reflectionCandidateIds) -contains [string]$stored[0].id -and
      [string]$_.source -eq 'reflection-promotion.ps1'
    }).Count | Should Be 1
  }

  It 'merges duplicate candidate instances into one stable family' {
    $workspace = Join-Path $TestDrive 'merge'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $seenAt = (Get-Date).AddDays(-2).ToString('yyyy-MM-dd HH:mm:ss')
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v1';items=@(
      (New-QueueCandidate 'old-a' 'gap' 'Same durable gap' $seenAt 2),
      (New-QueueCandidate 'old-b' 'gap' 'Same durable gap' $seenAt 3)
    )})

    $result = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-MaxActive','32','-Json')
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $result.exitCode | Should Be 0
    $result.value.merged | Should Be 1
    $result.value.archived | Should Be 2
    @($queue.items).Count | Should Be 1
    $queue.items[0].seenCount | Should Be 5
    $queue.items[0].mergedInstanceCount | Should Be 2
    ([string]$queue.items[0].familyKey).StartsWith('improvement-') | Should Be $true
    $archive = Get-Content -LiteralPath $result.value.archivePath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($archive.queueItems).Count | Should Be 2
  }

  It 'archives closed stale and over-budget candidates without deleting evidence' {
    $workspace = Join-Path $TestDrive 'archive'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $recent = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $old = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd HH:mm:ss')
    $items = @(
      (New-QueueCandidate 'high-repeat' 'risk' 'Keep high repeated risk' $recent 8 'high'),
      (New-QueueCandidate 'closed' 'gap' 'Closed lesson' $recent 2 'medium' 'adopted'),
      (New-QueueCandidate 'stale' 'gap' 'Stale singleton' $old 1 'medium')
    )
    foreach ($index in 1..10) { $items += New-QueueCandidate ("extra-$index") 'gap' ("Extra family $index") $recent 1 'low' }
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v1';items=$items })

    $result = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-MaxActive','8','-ArchiveAfterDays','14','-Json')
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $archive = Get-Content -LiteralPath $result.value.archivePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $result.exitCode | Should Be 0
    $result.value.active -le 8 | Should Be $true
    $result.value.archived -gt 0 | Should Be $true
    Test-Path -LiteralPath $result.value.archivePath | Should Be $true
    @($archive.queueItems | Where-Object { $_.id -eq 'closed' }).Count | Should Be 1
    @($archive.queueItems | Where-Object { $_.id -eq 'stale' }).Count | Should Be 1
    @($queue.items | Where-Object { $_.id -eq 'high-repeat' }).Count | Should Be 1
    ([string]$archive.restore).Length -gt 0 | Should Be $true
  }

  It 'rejects manual resolution even when a caller supplies an artifact-like string' {
    $workspace = Join-Path $TestDrive 'resolve'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v3';revision=0;items=@(
      (New-QueueCandidate 'candidate-a' 'gap' 'Verified family' $now 3 'medium' 'validated')
    )})

    $missing = Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId','candidate-a','-Resolution','resolved','-Json')
    $missing.exitCode | Should Not Be 0

    $freeText = Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId','candidate-a','-Resolution','resolved','-ResolutionEvidence','targeted replay passed','-Json')
    $freeText.exitCode | Should Not Be 0

    $artifactLike = Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId','candidate-a','-Resolution','resolved','-ResolutionEvidence','artifact:targeted-replay-001','-Json')
    $afterAttempt = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $artifactLike.exitCode | Should Not Be 0
    $afterAttempt.items[0].status | Should Be 'validated'
  }

  It 'reconciles a terminal reflection lifecycle into the queue' {
    $workspace = Join-Path $TestDrive 'reflection-resolution'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $reflectionPath = Join-Path $workspace 'reflection\candidates\learn-family.json'
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $item = New-QueueCandidate 'queue-family' 'reflection_candidate' 'Reusable verified lesson' $now 4 'medium'
    $item.source = 'reflection-promotion.ps1'
    $item | Add-Member -NotePropertyName target -NotePropertyValue 'experience' -Force
    $item | Add-Member -NotePropertyName scope -NotePropertyValue 'project-a' -Force
    $item | Add-Member -NotePropertyName reflectionCandidateIds -NotePropertyValue @('learn-family') -Force
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v2';items=@($item) })
    Write-QueueTestJson $reflectionPath ([pscustomobject]@{ id='learn-family';title='Reusable verified lesson';target='experience';scope='project-a';lifecycle=[pscustomobject]@{status='adopted';lastSeenAt=$now} })

    $result = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-Json')
    $archive = Get-Content -LiteralPath $result.value.archivePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $result.exitCode | Should Be 0
    $result.value.resolved | Should Be 1
    $result.value.total | Should Be 0
    @($archive.queueItems | Where-Object { $_.id -eq 'queue-family' -and $_.status -eq 'adopted' }).Count | Should Be 1
  }

  It 'does not reconcile a reflection lifecycle from a title match without the stable candidate id' {
    $workspace = Join-Path $TestDrive 'reflection-id-required'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $reflectionPath = Join-Path $workspace 'reflection\candidates\learn-other.json'
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $item = New-QueueCandidate 'queue-no-id' 'reflection_candidate' 'Same title is not identity' $now 1 'medium'
    $item.source = 'reflection-promotion.ps1'
    $item | Add-Member -NotePropertyName target -NotePropertyValue 'experience' -Force
    $item | Add-Member -NotePropertyName scope -NotePropertyValue 'project-a' -Force
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v3';revision=0;items=@($item) })
    Write-QueueTestJson $reflectionPath ([pscustomobject]@{ id='learn-other';title='Same title is not identity';target='experience';scope='project-a';lifecycle=[pscustomobject]@{status='adopted';lastSeenAt=$now} })

    $result = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-Json')
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $result.exitCode | Should Be 0
    $queue.items[0].status | Should Be 'candidate'
    $result.value.total | Should Be 1
  }

  It 'keeps a stable-id blocked reflection candidate visible for correction instead of archiving it' {
    $workspace = Join-Path $TestDrive 'reflection-blocked-visible'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $reflectionPath = Join-Path $workspace 'reflection\candidates\learn-blocked.json'
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $item = New-QueueCandidate 'queue-blocked' 'reflection_candidate' 'Blocked learning stays visible' $now 1 'medium'
    $item.source = 'reflection-promotion.ps1'
    $item | Add-Member -NotePropertyName target -NotePropertyValue 'experience' -Force
    $item | Add-Member -NotePropertyName scope -NotePropertyValue 'project-a' -Force
    $item | Add-Member -NotePropertyName reflectionCandidateIds -NotePropertyValue @('learn-blocked') -Force
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v3';revision=0;items=@($item) })
    Write-QueueTestJson $reflectionPath ([pscustomobject]@{ id='learn-blocked';title='Blocked learning stays visible';target='experience';scope='project-a';lifecycle=[pscustomobject]@{status='blocked';lastSeenAt=$now} })

    $result = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-Json')
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $result.exitCode | Should Be 0
    $queue.items[0].status | Should Be 'blocked'
    Test-Path -LiteralPath $reflectionPath | Should Be $true
    $result.value.reflectionArchived | Should Be 0
  }

  It 'syncs exact skill-evolution proposal lifecycle without auto-adopting it' {
    $workspace = Join-Path $TestDrive 'proposal-sync'
    $proposalPath = Write-SkillEvolutionProposal $workspace 'proposal-phase6-001' 'staged'

    $staged = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-Json')
    $staged.exitCode | Should Be 0
    $staged.value.proposalSynced | Should Be 1
    $queue = Get-Content -LiteralPath (Join-Path $workspace 'self-improvement-queue.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $queue.items[0].status | Should Be 'candidate'
    $queue.items[0].governanceLifecycleStage | Should Be 'candidate'
    $queue.items[0].proposalLinks[0].proposalId | Should Be 'proposal-phase6-001'
    $queue.items[0].autoResolutionEligible | Should Be $false

    Write-SkillEvolutionProposal $workspace 'proposal-phase6-001' 'validated' | Out-Null
    $validated = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-Json')
    $validated.exitCode | Should Be 0
    $queue = Get-Content -LiteralPath (Join-Path $workspace 'self-improvement-queue.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $queue.items[0].status | Should Be 'staged'
    $queue.items[0].governanceLifecycleStage | Should Be 'staged'

    Write-SkillEvolutionProposal $workspace 'proposal-phase6-001' 'rejected' | Out-Null
    $rejected = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-Json')
    $rejected.exitCode | Should Be 0
    $archive = Get-Content -LiteralPath $rejected.value.archivePath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($archive.queueItems | Where-Object { $_.proposalLinks[0].proposalId -eq 'proposal-phase6-001' -and $_.status -eq 'rejected' }).Count | Should Be 1
    $activeProposal = $rejected.value.recent | Where-Object { $_.proposalLinks[0].proposalId -eq 'proposal-phase6-001' }
    $activeProposal | Should BeNullOrEmpty
  }

  It 'requires three distinct task-bound receipts before eligible evidence-only auto-resolution' {
    $workspace = Join-Path $TestDrive 'verification-receipts'
    $workspaceKey = 'ws-learning-receipt-001'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $eligible = New-QueueCandidate 'candidate-evidence' 'evidence_observation' 'Bounded evidence-only observation' $now 1 'low' 'validated' $true 'low' 'evidence_only'
    $ineligible = New-QueueCandidate 'candidate-governed' 'skill_evolution_proposal' 'Governed proposal stays human-approved' $now 1 'low' 'validated' $false 'low' 'governed_change'
    Write-QueueTestJson $queuePath ([pscustomobject]@{schema='super-brain.self-improvement-queue.v3';revision=0;items=@($eligible,$ineligible)})

    $first = Write-LearningReceipt $workspace 'receipt-001' 'task-receipt-001' $workspaceKey
    $one = Invoke-QueueTest @('-Action','RecordVerification','-WorkspaceRoot',$workspace,'-CandidateId','candidate-evidence','-VerificationId','receipt-001','-VerificationEvidenceRef',('receipt:' + $first.sha256),'-VerificationTaskId','task-receipt-001','-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$first.path,'-Json')
    $one.exitCode | Should Be 0
    $one.value.autoResolved | Should Be 0

    $duplicate = Invoke-QueueTest @('-Action','RecordVerification','-WorkspaceRoot',$workspace,'-CandidateId','candidate-evidence','-VerificationId','receipt-001','-VerificationEvidenceRef',('receipt:' + $first.sha256),'-VerificationTaskId','task-receipt-001','-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$first.path,'-Json')
    $duplicate.exitCode | Should Not Be 0

    foreach ($n in 2..3) {
      $receipt = Write-LearningReceipt $workspace ("receipt-00$n") ("task-receipt-00$n") $workspaceKey
      $record = Invoke-QueueTest @('-Action','RecordVerification','-WorkspaceRoot',$workspace,'-CandidateId','candidate-evidence','-VerificationId',("receipt-00$n"),'-VerificationEvidenceRef',('receipt:' + $receipt.sha256),'-VerificationTaskId',("task-receipt-00$n"),'-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$receipt.path,'-Json')
      $record.exitCode | Should Be 0
    }
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    (@($queue.items | Where-Object { $_.id -eq 'candidate-evidence' })[0].status) | Should Be 'resolved'
    (@($queue.items | Where-Object { $_.id -eq 'candidate-evidence' })[0].resolutionSource) | Should Be 'self-improvement-queue.ps1:auto-evidence-only'
    (@($queue.items | Where-Object { $_.id -eq 'candidate-evidence' })[0].verificationReceipts).Count | Should Be 3

    foreach ($n in 1..3) {
      $receipt = Write-LearningReceipt $workspace ("receipt-governed-00$n") ("task-governed-00$n") $workspaceKey
      $record = Invoke-QueueTest @('-Action','RecordVerification','-WorkspaceRoot',$workspace,'-CandidateId','candidate-governed','-VerificationId',("receipt-governed-00$n"),'-VerificationEvidenceRef',('receipt:' + $receipt.sha256),'-VerificationTaskId',("task-governed-00$n"),'-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$receipt.path,'-Json')
      $record.exitCode | Should Be 0
      $record.value.autoResolved | Should Be 0
    }
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    (@($queue.items | Where-Object { $_.id -eq 'candidate-governed' })[0].status) | Should Be 'validated'

    $sameTask = New-QueueCandidate 'candidate-same-task' 'evidence_observation' 'One task cannot satisfy three receipts' $now 1 'low' 'validated' $true 'low' 'evidence_only'
    $queue.items = @($queue.items) + @($sameTask)
    Write-QueueTestJson $queuePath $queue
    foreach ($n in 1..3) {
      $receipt = Write-LearningReceipt $workspace ("receipt-same-task-00$n") 'task-same-receipt' $workspaceKey
      $record = Invoke-QueueTest @('-Action','RecordVerification','-WorkspaceRoot',$workspace,'-CandidateId','candidate-same-task','-VerificationId',("receipt-same-task-00$n"),'-VerificationEvidenceRef',('receipt:' + $receipt.sha256),'-VerificationTaskId','task-same-receipt','-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$receipt.path,'-Json')
      $record.exitCode | Should Be 0
      $record.value.autoResolved | Should Be 0
    }
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    (@($queue.items | Where-Object { $_.id -eq 'candidate-same-task' })[0].status) | Should Be 'validated'
  }

  It 'rejects unvalidated resolution, unapproved adoption, and private receipt references' {
    $workspace = Join-Path $TestDrive 'transition-gates'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-QueueTestJson $queuePath ([pscustomobject]@{schema='super-brain.self-improvement-queue.v3';revision=0;items=@(
      (New-QueueCandidate 'candidate-raw' 'gap' 'Raw candidate' $now),
      (New-QueueCandidate 'candidate-validated' 'gap' 'Validated candidate' $now 1 'medium' 'validated')
    )})

    (Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId','candidate-raw','-Resolution','resolved','-ResolutionEvidence','artifact:verified-replay-001','-Json')).exitCode | Should Not Be 0
    (Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId','candidate-validated','-Resolution','adopted','-ResolutionEvidence','artifact:verified-replay-002','-Json')).exitCode | Should Not Be 0
    (Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId','candidate-validated','-Resolution','adopted','-ResolutionEvidence','approval:review-002','-Json')).exitCode | Should Not Be 0

    $receipt = Write-LearningReceipt $workspace 'receipt-private-001' 'task-private-001' 'ws-private-001'
    (Invoke-QueueTest @('-Action','RecordVerification','-WorkspaceRoot',$workspace,'-CandidateId','candidate-raw','-VerificationId','receipt-private-001','-VerificationEvidenceRef','receipt:raw-prompt-text','-VerificationTaskId','task-private-001','-VerificationWorkspaceKey','ws-private-001','-VerificationReceiptPath',$receipt.path,'-Json')).exitCode | Should Not Be 0
  }

  It 'rejects a stale expected revision before it can mutate a validated candidate' {
    $workspace = Join-Path $TestDrive 'revision-conflict'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-QueueTestJson $queuePath ([pscustomobject]@{schema='super-brain.self-improvement-queue.v3';revision=3;items=@(
      (New-QueueCandidate 'candidate-revision' 'gap' 'Revision guarded candidate' $now 1 'medium' 'validated')
    )})

    $stale = Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId','candidate-revision','-Resolution','resolved','-ResolutionEvidence','artifact:revision-replay-001','-ExpectedRevision','2','-Json')
    $stale.exitCode | Should Not Be 0
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $queue.revision | Should Be 3
    $queue.items[0].status | Should Be 'validated'
  }

  It 'projects a governed proposal only after approved measured adoption and three independent pass receipts' {
    $workspace = Join-Path $TestDrive 'governed-proposal-closeout'
    $workspaceKey = 'ws-p3-effect-001'
    $proposalId = 'proposal-p3-effect-001'
    $fingerprint = 'proposal-fingerprint-p3-001'
    $proposalPath = Write-SkillEvolutionProposal $workspace $proposalId 'validated' $fingerprint
    (Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-Json')).exitCode | Should Be 0
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $candidateId = [string]$queue.items[0].id

    (Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId',$candidateId,'-Resolution','adopted','-ResolutionEvidence','artifact:replay-p3-001','-Json')).exitCode | Should Not Be 0

    $adoptionTaskId = 'task-p3-adoption-001'
    $adoptionReceipt = Write-LearningReceipt $workspace 'receipt-p3-adoption-001' $adoptionTaskId $workspaceKey
    $foreignScopeEffectPath = Write-LearningEffectArtifact $workspace $proposalId $fingerprint 'task-p3-foreign-001' $workspaceKey 'sid-learning-test'
    (Invoke-QueueTest @(
      '-Action','IssueAdoptionReceipt','-WorkspaceRoot',$workspace,'-CandidateId',$candidateId,
      '-TaskId',$adoptionTaskId,'-VerificationId','receipt-p3-adoption-001','-VerificationTaskId',$adoptionTaskId,
      '-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$adoptionReceipt.path,
      '-OwnerSessionKey','sid-learning-test','-EffectArtifactPath',$foreignScopeEffectPath,
      '-ApprovalInstructionHash',(('a' * 64) -join ''),'-ConfirmAdoption','-Json'
    )).exitCode | Should Not Be 0
    $noGainEffectPath = Write-LearningEffectArtifact $workspace $proposalId $fingerprint $adoptionTaskId $workspaceKey 'sid-learning-test' 3 3
    (Invoke-QueueTest @(
      '-Action','IssueAdoptionReceipt','-WorkspaceRoot',$workspace,'-CandidateId',$candidateId,
      '-TaskId',$adoptionTaskId,'-VerificationId','receipt-p3-adoption-001','-VerificationTaskId',$adoptionTaskId,
      '-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$adoptionReceipt.path,
      '-OwnerSessionKey','sid-learning-test','-EffectArtifactPath',$noGainEffectPath,
      '-ApprovalInstructionHash',(('b' * 64) -join ''),'-ConfirmAdoption','-Json'
    )).exitCode | Should Not Be 0
    $effectPath = Write-LearningEffectArtifact $workspace $proposalId $fingerprint $adoptionTaskId $workspaceKey 'sid-learning-test'
    (Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId',$candidateId,'-Resolution','adopted','-ResolutionEvidence','approval:review-p3-001','-EffectArtifactPath',$effectPath,'-Json')).exitCode | Should Not Be 0
    $issued = Invoke-QueueTest @(
      '-Action','IssueAdoptionReceipt','-WorkspaceRoot',$workspace,'-CandidateId',$candidateId,
      '-TaskId',$adoptionTaskId,'-VerificationId','receipt-p3-adoption-001','-VerificationTaskId',$adoptionTaskId,
      '-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$adoptionReceipt.path,
      '-OwnerSessionKey','sid-learning-test','-EffectArtifactPath',$effectPath,
      '-ApprovalInstructionHash',(('c' * 64) -join ''),'-ConfirmAdoption','-Json'
    )
    $issued.exitCode | Should Be 0
    $issued.value.adoptionReceipt.sha256 | Should Match '^[a-f0-9]{64}$'
    (Invoke-QueueTest @(
      '-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId',$candidateId,'-Resolution','adopted',
      '-TaskId',$adoptionTaskId,'-VerificationWorkspaceKey',$workspaceKey,'-OwnerSessionKey','sid-learning-test',
      '-AdoptionReceiptPath',$issued.value.adoptionReceipt.path,'-AdoptionReceiptSha256',(('0' * 64) -join ''),
      '-EffectArtifactPath',$effectPath,'-Json'
    )).exitCode | Should Not Be 0
    $adopted = Invoke-QueueTest @(
      '-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId',$candidateId,'-Resolution','adopted',
      '-TaskId',$adoptionTaskId,'-VerificationWorkspaceKey',$workspaceKey,'-OwnerSessionKey','sid-learning-test',
      '-AdoptionReceiptPath',$issued.value.adoptionReceipt.path,'-AdoptionReceiptSha256',$issued.value.adoptionReceipt.sha256,
      '-EffectArtifactPath',$effectPath,'-Json'
    )
    $adopted.exitCode | Should Be 0
    $adopted.value.proposalProjectionCount | Should Be 1
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $queue.items[0].status | Should Be 'adopted'
    $queue.items[0].effect.status | Should Be 'scored'
    $queue.items[0].effect.delta | Should Be 0.25
    $proposal = Get-Content -LiteralPath $proposalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $proposal.status | Should Be 'adopted'
    $proposal.lifecycle.authority | Should Be 'self-improvement-queue.ps1'
    $proposal.effect.improvementClaimAllowed | Should Be $true

    (Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId',$candidateId,'-Resolution','resolved','-ResolutionEvidence','artifact:premature-closeout','-Json')).exitCode | Should Not Be 0

    foreach ($n in 1..3) {
      $receipt = Write-LearningReceipt $workspace ("receipt-p3-$n") ("task-p3-$n") $workspaceKey
      $record = Invoke-QueueTest @('-Action','RecordVerification','-WorkspaceRoot',$workspace,'-CandidateId',$candidateId,'-VerificationId',("receipt-p3-$n"),'-VerificationEvidenceRef',('receipt:' + $receipt.sha256),'-VerificationTaskId',("task-p3-$n"),'-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$receipt.path,'-Json')
      $record.exitCode | Should Be 0
    }

    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $queue.items[0].status | Should Be 'resolved'
    $queue.items[0].resolutionSource | Should Be 'self-improvement-queue.ps1:three-independent-learning-receipts'
    $proposal = Get-Content -LiteralPath $proposalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $proposal.status | Should Be 'resolved'
    $proposal.lifecycle.queueCandidateId | Should Be $candidateId
    $proposal.effect.status | Should Be 'scored'
  }

  It 'writes a staged reflection lesson only through a current receipt into an isolated memory root' {
    $originalStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $stateRoot = Join-Path $TestDrive 'controlled-memory-real-path-state'
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $memoryRoot = Initialize-IsolatedQueueMemory $stateRoot
      . (Join-Path $root 'scripts\common.ps1')
      $workspace = Join-Path $stateRoot 'workspace'
      # ReflectionPromotion.Tests.ps1 owns the full reflection engine.  This
      # test isolates the queue-to-memory transaction using the same persisted
      # candidate shape, while the staged-import test above keeps one real
      # Reflection -> Queue integration chain in this suite.
      $fixture = Write-ReflectionCandidateFixture $workspace
      $fixture.candidate.lifecycle.status | Should Be 'staged'
      (Invoke-QueueTest @('-Action','Collect','-WorkspaceRoot',$workspace,'-Json')).exitCode | Should Be 0
      $queuePath = Join-Path $workspace 'self-improvement-queue.json'
      $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $candidate = @($queue.items | Where-Object {
        [string]$_.source -eq 'reflection-promotion.ps1' -and
        [string]$_.target -in @('experience','memory') -and
        @($_.reflectionCandidateIds) -contains [string]$fixture.candidate.id
      } | Select-Object -First 1)[0]
      $candidate | Should Not BeNullOrEmpty

      $taskId = 'task-controlled-memory-real-001'
      $workspaceKey = 'ws-controlled-memory-real-001'
      $receiptId = 'receipt-controlled-memory-real-001'
      $receipt = Write-LearningReceipt $workspace $receiptId $taskId $workspaceKey
      $before = Get-IsolatedMemoryLineCount $memoryRoot
      $unvalidated = Invoke-QueueTest @(
        '-Action','IssueAdoptionReceipt','-WorkspaceRoot',$workspace,'-CandidateId',[string]$candidate.id,
        '-TaskId',$taskId,'-VerificationId',$receiptId,'-VerificationTaskId',$taskId,'-VerificationWorkspaceKey',$workspaceKey,
        '-VerificationReceiptPath',$receipt.path,'-OwnerSessionKey','sid-learning-test',
        '-ApprovalInstructionHash',(('a' * 64) -join ''),'-ConfirmAdoption','-Json'
      )
      $unvalidated.exitCode | Should Not Be 0
      (Get-IsolatedMemoryLineCount $memoryRoot) | Should Be $before

      $record = Invoke-QueueTest @(
        '-Action','RecordVerification','-WorkspaceRoot',$workspace,'-CandidateId',[string]$candidate.id,
        '-VerificationId',$receiptId,'-VerificationEvidenceRef',('receipt:' + $receipt.sha256),
        '-VerificationTaskId',$taskId,'-VerificationWorkspaceKey',$workspaceKey,'-VerificationReceiptPath',$receipt.path,'-Json'
      )
      $record.exitCode | Should Be 0
      $wrongSession = Invoke-QueueTest @(
        '-Action','IssueAdoptionReceipt','-WorkspaceRoot',$workspace,'-CandidateId',[string]$candidate.id,
        '-TaskId',$taskId,'-VerificationId',$receiptId,'-VerificationTaskId',$taskId,'-VerificationWorkspaceKey',$workspaceKey,
        '-VerificationReceiptPath',$receipt.path,'-OwnerSessionKey','sid-wrong-session',
        '-ApprovalInstructionHash',(('b' * 64) -join ''),'-ConfirmAdoption','-Json'
      )
      $wrongSession.exitCode | Should Not Be 0
      (Get-IsolatedMemoryLineCount $memoryRoot) | Should Be $before

      $issued = Invoke-QueueTest @(
        '-Action','IssueAdoptionReceipt','-WorkspaceRoot',$workspace,'-CandidateId',[string]$candidate.id,
        '-TaskId',$taskId,'-VerificationId',$receiptId,'-VerificationTaskId',$taskId,'-VerificationWorkspaceKey',$workspaceKey,
        '-VerificationReceiptPath',$receipt.path,'-OwnerSessionKey','sid-learning-test',
        '-ApprovalInstructionHash',(('c' * 64) -join ''),'-ConfirmAdoption','-Json'
      )
      $issued.exitCode | Should Be 0
      $adopted = Invoke-QueueTest @(
        '-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId',[string]$candidate.id,'-Resolution','adopted',
        '-TaskId',$taskId,'-VerificationWorkspaceKey',$workspaceKey,'-OwnerSessionKey','sid-learning-test',
        '-AdoptionReceiptPath',$issued.value.adoptionReceipt.path,'-AdoptionReceiptSha256',$issued.value.adoptionReceipt.sha256,'-Json'
      )
      $adopted.exitCode | Should Be 0

      $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $item = @($queue.items | Where-Object { [string]$_.id -eq [string]$candidate.id })[0]
      $transactionPath = Join-Path $workspace ([string]$item.promotionTransaction.relativePath).Replace('/','\')
      $transaction = Get-Content -LiteralPath $transactionPath -Raw -Encoding UTF8 | ConvertFrom-Json
      # Collect may merge a Preview-only candidate id before the persisted
      # Apply candidate.  Only ids that have a real candidate file can be
      # promoted, so assert the lifecycle on every persisted linked candidate
      # instead of treating list order as a persistence guarantee.
      $reflectionSnapshots = @(
        Get-ChildItem -LiteralPath (Join-Path $workspace 'reflection\candidates') -Filter '*.json' -File |
          ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } |
          Where-Object { @($item.reflectionCandidateIds) -contains [string]$_.id }
      )

      $item.status | Should Be 'adopted'
      $transaction.state | Should Be 'committed'
      $reflectionSnapshots.Count | Should BeGreaterThan 0
      @($reflectionSnapshots | Where-Object { [string]$_.lifecycle.status -ne 'adopted' }).Count | Should Be 0
      (Get-IsolatedMemoryLineCount $memoryRoot) | Should BeGreaterThan $before
      (Get-Content -LiteralPath (Join-Path $memoryRoot 'sandglass.txt') -Raw -Encoding UTF8) | Should Match 'source=learn-memory.ps1'
      $adopted.value.queuePath.StartsWith($workspace, [System.StringComparison]::OrdinalIgnoreCase) | Should Be $true
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $originalStateRoot
    }
  }

  It 'commits an interrupted post-write controlled promotion without writing memory twice' {
    $originalStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $stateRoot = Join-Path $TestDrive 'controlled-memory-replay-state'
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $memoryRoot = Initialize-IsolatedQueueMemory $stateRoot
      . (Join-Path $root 'scripts\common.ps1')
      $workspace = Join-Path $stateRoot 'workspace'
      $queuePath = Join-Path $workspace 'self-improvement-queue.json'
      $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      $candidate = New-QueueCandidate 'candidate-controlled-replay-001' 'reflection_candidate' 'Replay-safe controlled lesson' $now 1 'medium' 'validated'
      $candidate.source = 'reflection-promotion.ps1'
      $candidate | Add-Member -NotePropertyName target -NotePropertyValue 'experience' -Force
      $candidate | Add-Member -NotePropertyName scope -NotePropertyValue 'project' -Force
      $candidate | Add-Member -NotePropertyName reflectionCandidateIds -NotePropertyValue @() -Force
      Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v3';revision=0;items=@($candidate) })

      $taskId = 'task-controlled-replay-001'
      $workspaceKey = 'ws-controlled-replay-001'
      $receiptId = 'receipt-controlled-replay-001'
      $receipt = Write-LearningReceipt $workspace $receiptId $taskId $workspaceKey
      $issued = Invoke-QueueTest @(
        '-Action','IssueAdoptionReceipt','-WorkspaceRoot',$workspace,'-CandidateId',$candidate.id,
        '-TaskId',$taskId,'-VerificationId',$receiptId,'-VerificationTaskId',$taskId,'-VerificationWorkspaceKey',$workspaceKey,
        '-VerificationReceiptPath',$receipt.path,'-OwnerSessionKey','sid-learning-test',
        '-ApprovalInstructionHash',(('d' * 64) -join ''),'-ConfirmAdoption','-Json'
      )
      $issued.exitCode | Should Be 0
      $transactionRoot = Join-Path $workspace 'runtime-state\learning-promotion-transactions'
      $transactionPath = Join-Path $transactionRoot (('c-' + (Get-SuperBrainStableHash $candidate.id 16) + '--' + $issued.value.adoptionReceipt.sha256 + '.json'))
      $prewritten = '2026-07-28 00:00:00 | user | [CURRENT][VERIFIED][PROJECT] replay-safe memory source=learn-memory.ps1'
      [IO.File]::WriteAllText((Join-Path $memoryRoot 'sandglass.txt'), $prewritten + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
      Write-QueueTestJson $transactionPath ([pscustomobject]@{
        schema='super-brain.controlled-memory-promotion-transaction.v1';candidateId=$candidate.id;target='experience';memoryLayer='experience';
        titleHash=(Get-SuperBrainStableHash $candidate.title 32);summaryHash=(Get-SuperBrainStableHash $candidate.problem 32);
        adoptionReceiptSha256=$issued.value.adoptionReceipt.sha256;taskId=$taskId;workspaceKey=$workspaceKey;ownerSessionKey='sid-learning-test';
        packageVersion=(Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version;
        state='memory_written';preparedAt=(Get-Date).ToString('o');wroteAt=(Get-Date).ToString('o');
        privacy=[pscustomobject]@{rawPromptStored=$false;rawSummaryStored=$false;rawTranscriptStored=$false};
        writerResult=[pscustomobject]@{ok=$true;preview=$false;decision='write_memory_and_experience';rawPromptStored=$false}
      })
      $before = Get-IsolatedMemoryLineCount $memoryRoot
      $adopted = Invoke-QueueTest @(
        '-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId',$candidate.id,'-Resolution','adopted',
        '-TaskId',$taskId,'-VerificationWorkspaceKey',$workspaceKey,'-OwnerSessionKey','sid-learning-test',
        '-AdoptionReceiptPath',$issued.value.adoptionReceipt.path,'-AdoptionReceiptSha256',$issued.value.adoptionReceipt.sha256,'-Json'
      )
      $adopted.exitCode | Should Be 0
      $transaction = Get-Content -LiteralPath $transactionPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $transaction.state | Should Be 'committed'
      $queue.items[0].status | Should Be 'adopted'
      (Get-IsolatedMemoryLineCount $memoryRoot) | Should Be $before
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $originalStateRoot
    }
  }
}
