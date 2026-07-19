$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$storeScript = Join-Path $root 'scripts\task-state-store.ps1'
. (Join-Path $root 'scripts\common.ps1')
$script:DefaultTaskStateOwner = [pscustomobject]@{ agentId='agent-test'; sessionId='session-test'; platform='codex'; workspace='G:\task-state-tests' }

function Write-TestJson([string]$Path,[object]$Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}

function Invoke-TaskStateStore([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $storeScript @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text) -or $text.Trim() -eq 'null') { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

function Get-TestTaskStateOwnerArgs([object]$Owner = $script:DefaultTaskStateOwner) {
  return @('-OwnerAgentId',[string]$Owner.agentId,'-OwnerSessionId',[string]$Owner.sessionId,'-OwnerPlatform',[string]$Owner.platform,'-OwnerWorkspace',[string]$Owner.workspace)
}

function Get-TestTaskStateTarget([string]$Workspace,[string]$Shared,[string]$TaskId,[string]$Kind,[string]$Lifecycle = 'active') {
  switch ($Kind) {
    'context' { return Get-SuperBrainCanonicalTaskPath (Join-Path $Workspace 'guard-state\current-task-contexts') $TaskId '.json' }
    'checkpoint' { return Get-SuperBrainCanonicalTaskPath (Join-Path $Workspace ("runtime-state\checkpoints\" + $Lifecycle)) $TaskId '.json' }
    'task_card' { return Get-SuperBrainCanonicalTaskPath (Join-Path $Shared ("tasks\" + $Lifecycle)) $TaskId '.task.json' }
  }
  throw "Unknown task-state kind: $Kind"
}

function Invoke-NormalTaskStateCommit(
  [string]$TaskId,
  [string]$EntityKind,
  [string]$EntityPath,
  [string]$PayloadPath = '',
  [ValidateSet('upsert','clear')][string]$Operation = 'upsert',
  [int]$ExpectedRevision = 0,
  [string]$Workspace,
  [string]$Shared,
  [object]$Owner = $script:DefaultTaskStateOwner,
  [string]$Source = 'TaskStateStore.Tests.ps1',
  [string]$FaultPoint = 'none'
) {
  $arguments = @('-Action','Commit','-TaskId',$TaskId,'-EntityKind',$EntityKind,'-Operation',$Operation,'-EntityPath',$EntityPath,'-ExpectedRevision',[string]$ExpectedRevision,'-WorkspaceRoot',$Workspace,'-SharedRoot',$Shared,'-Source',$Source,'-Json')
  if ($PayloadPath) { $arguments += @('-PayloadPath',$PayloadPath) }
  if ($FaultPoint -ne 'none') { $arguments += @('-FaultPoint',$FaultPoint) }
  $arguments += Get-TestTaskStateOwnerArgs $Owner
  return Invoke-TaskStateStore $arguments
}

function Invoke-MaintenanceTaskStateRecord([string]$TaskId,[string]$EntityKind,[string]$EntityPath,[string]$Workspace,[string]$Shared,[int]$ExpectedRevision = -1) {
  return Invoke-TaskStateStore @('-Action','Record','-TaskId',$TaskId,'-EntityKind',$EntityKind,'-EntityPath',$EntityPath,'-ExpectedRevision',[string]$ExpectedRevision,'-WorkspaceRoot',$Workspace,'-SharedRoot',$Shared,'-MaintenanceOverride','-MaintenanceReason','isolated legacy import regression','-Json')
}

Describe 'TaskStateStore' {
  It 'records monotonic revisions and rejects stale CAS without appending' {
    $workspace = Join-Path $TestDrive 'cas\workspace'
    $shared = Join-Path $TestDrive 'cas\shared'
    $entity = Join-Path $TestDrive 'cas\task.json'
    Write-TestJson $entity ([pscustomobject]@{ taskId='task-cas'; status='active'; body='not copied into events'; value=1 })

    $first = Invoke-MaintenanceTaskStateRecord 'task-cas' 'task_card' $entity $workspace $shared 0
    $first.exitCode | Should Be 0
    $first.value.revision | Should Be 1

    Write-TestJson $entity ([pscustomobject]@{ taskId='task-cas'; status='active'; body='not copied into events'; value=2 })
    $second = Invoke-MaintenanceTaskStateRecord 'task-cas' 'task_card' $entity $workspace $shared 1
    $second.exitCode | Should Be 0
    $second.value.revision | Should Be 2

    $stale = Invoke-MaintenanceTaskStateRecord 'task-cas' 'task_card' $entity $workspace $shared 1
    $stale.exitCode | Should Be 1
    $stale.value.error.Contains('TASK_STATE_CAS_MISMATCH') | Should Be $true

    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-cas' '.jsonl'
    @(Get-Content -LiteralPath $eventPath -Encoding UTF8).Count | Should Be 2
    (Get-Content -LiteralPath $eventPath -Raw -Encoding UTF8).Contains('not copied into events') | Should Be $false
  }

  It 'rebuilds the same projection from append-only events' {
    $workspace = Join-Path $TestDrive 'rebuild\workspace'
    $shared = Join-Path $TestDrive 'rebuild\shared'
    $entity = Join-Path $TestDrive 'rebuild\context.json'
    Write-TestJson $entity ([pscustomobject]@{ taskId='task-rebuild'; status='active'; acceptedGoal='goal' })
    $record = Invoke-MaintenanceTaskStateRecord 'task-rebuild' 'context' $entity $workspace $shared
    $record.exitCode | Should Be 0
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') 'task-rebuild' '.json'
    Remove-Item -LiteralPath $projectionPath -Force

    $dry = Invoke-TaskStateStore @('-Action','Rebuild','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $dry.value.applied | Should Be $false
    Test-Path -LiteralPath $projectionPath | Should Be $false

    $applied = Invoke-TaskStateStore @('-Action','Rebuild','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $applied.exitCode | Should Be 0
    $applied.value.projectionCount | Should Be 1
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.revision | Should Be 1
    $projection.entities.context.hash | Should Be (Get-FileHash -LiteralPath $entity -Algorithm SHA256).Hash
  }

  It 'materializes a staged command through prepared and committed WAL events' {
    $workspace = Join-Path $TestDrive 'commit\workspace'
    $shared = Join-Path $TestDrive 'commit\shared'
    $payload = Join-Path $TestDrive 'commit\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-commit' 'context'
    Write-TestJson $payload ([pscustomobject]@{ taskId='task-commit'; status='active'; acceptedGoal='commit through store' })

    $commit = Invoke-NormalTaskStateCommit -TaskId 'task-commit' -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared
    $commit.exitCode | Should Be 0
    $commit.value.revision | Should Be 1
    $commit.value.transactionId.Length -gt 0 | Should Be $true
    Test-Path -LiteralPath $target | Should Be $true
    (Get-Content -Raw -Encoding UTF8 -LiteralPath $target | ConvertFrom-Json).acceptedGoal | Should Be 'commit through store'
    $events = @(Get-Content -Encoding UTF8 -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-commit' '.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    @($events).Count | Should Be 2
    @($events.phase) | Should Be @('prepared','committed')
    ($events | ConvertTo-Json -Depth 8).Contains('commit through store') | Should Be $false
  }

  It 'reconciles a crash after WAL prepare without duplicating a revision' {
    $workspace = Join-Path $TestDrive 'reconcile\workspace'
    $shared = Join-Path $TestDrive 'reconcile\shared'
    $payload = Join-Path $workspace 'task-state-store\staging\task-reconcile\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-reconcile' 'context'
    Write-TestJson $payload ([pscustomobject]@{ taskId='task-reconcile'; status='active'; acceptedGoal='recover me' })

    $failed = Invoke-NormalTaskStateCommit -TaskId 'task-reconcile' -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared -FaultPoint after_prepare
    $failed.exitCode | Should Be 1
    $failed.value.error.Contains('TASK_STATE_FAULT_INJECTED_AFTER_PREPARE') | Should Be $true
    Test-Path -LiteralPath $target | Should Be $false

    $auditBefore = Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $auditBefore.exitCode | Should Be 1
    $auditBefore.value.incompleteTransactionCount | Should Be 1
    $reconciled = Invoke-TaskStateStore @('-Action','Reconcile','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $reconciled.exitCode | Should Be 0
    $reconciled.value.recoveredCount | Should Be 1
    (Get-Content -Raw -Encoding UTF8 -LiteralPath $target | ConvertFrom-Json).acceptedGoal | Should Be 'recover me'
    (Get-Content -Raw -Encoding UTF8 -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') 'task-reconcile' '.json') | ConvertFrom-Json).revision | Should Be 1
    (Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')).value.incompleteTransactionCount | Should Be 0
  }

  It 'reconciles a crash after materialization without rewriting the payload' {
    $workspace = Join-Path $TestDrive 'reconcile-materialized\workspace'
    $shared = Join-Path $TestDrive 'reconcile-materialized\shared'
    $payload = Join-Path $workspace 'task-state-store\staging\task-reconcile-materialized\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-reconcile-materialized' 'context'
    Write-TestJson $payload ([pscustomobject]@{ taskId='task-reconcile-materialized'; status='active'; acceptedGoal='already materialized' })

    $failed = Invoke-NormalTaskStateCommit -TaskId 'task-reconcile-materialized' -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared -FaultPoint after_materialize
    $failed.exitCode | Should Be 1
    $failed.value.error.Contains('TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZE') | Should Be $true
    Test-Path -LiteralPath $target | Should Be $true
    $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash

    $reconciled = Invoke-TaskStateStore @('-Action','Reconcile','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $reconciled.exitCode | Should Be 0
    $reconciled.value.recoveredCount | Should Be 1
    (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash | Should Be $targetHash
    $events = @(Get-Content -Encoding UTF8 -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-reconcile-materialized' '.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $events.Count | Should Be 2
    @($events.phase) | Should Be @('prepared','committed')
    $events[1].recovered | Should Be $true
    (Get-Content -Raw -Encoding UTF8 -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') 'task-reconcile-materialized' '.json') | ConvertFrom-Json).revision | Should Be 1
  }

  It 'rejects cross-task targets and payload identities before materializing' {
    $workspace = Join-Path $TestDrive 'identity\workspace'
    $shared = Join-Path $TestDrive 'identity\shared'
    $payload = Join-Path $TestDrive 'identity\payload.json'
    $taskA = 'task/a'
    $taskB = 'task?a'
    $targetA = Get-TestTaskStateTarget $workspace $shared $taskA 'context'
    $targetB = Get-TestTaskStateTarget $workspace $shared $taskB 'context'
    Write-TestJson $payload ([pscustomobject]@{ taskId=$taskA; status='active'; value='task-a' })

    $crossTask = Invoke-NormalTaskStateCommit -TaskId $taskA -EntityKind context -PayloadPath $payload -EntityPath $targetB -ExpectedRevision 0 -Workspace $workspace -Shared $shared
    $crossTask.exitCode | Should Be 1
    $crossTask.value.error.Contains('TASK_STATE_TARGET_TASK_MISMATCH') | Should Be $true
    Test-Path -LiteralPath $targetB | Should Be $false

    Write-TestJson $payload ([pscustomobject]@{ taskId=$taskB; status='active'; value='task-b' })
    $identityMismatch = Invoke-NormalTaskStateCommit -TaskId $taskA -EntityKind context -PayloadPath $payload -EntityPath $targetA -ExpectedRevision 0 -Workspace $workspace -Shared $shared
    $identityMismatch.exitCode | Should Be 1
    $identityMismatch.value.error.Contains('TASK_STATE_IDENTITY_MISMATCH') | Should Be $true
    Test-Path -LiteralPath $targetA | Should Be $false
  }

  It 'keeps lossy-safe-name collisions in independent canonical files and journals' {
    $workspace = Join-Path $TestDrive 'collision\workspace'
    $shared = Join-Path $TestDrive 'collision\shared'
    $taskA = 'task/a'
    $taskB = 'task?a'
    $payloadA = Join-Path $TestDrive 'collision\payload-a.json'
    $payloadB = Join-Path $TestDrive 'collision\payload-b.json'
    $targetA = Get-TestTaskStateTarget $workspace $shared $taskA 'context'
    $targetB = Get-TestTaskStateTarget $workspace $shared $taskB 'context'
    Write-TestJson $payloadA ([pscustomobject]@{ taskId=$taskA; status='active'; value='a' })
    Write-TestJson $payloadB ([pscustomobject]@{ taskId=$taskB; status='active'; value='b' })

    (Invoke-NormalTaskStateCommit -TaskId $taskA -EntityKind context -PayloadPath $payloadA -EntityPath $targetA -ExpectedRevision 0 -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    (Invoke-NormalTaskStateCommit -TaskId $taskB -EntityKind context -PayloadPath $payloadB -EntityPath $targetB -ExpectedRevision 0 -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    $targetA | Should Not Be $targetB
    (Get-Content -Raw -Encoding UTF8 -LiteralPath $targetA | ConvertFrom-Json).value | Should Be 'a'
    (Get-Content -Raw -Encoding UTF8 -LiteralPath $targetB | ConvertFrom-Json).value | Should Be 'b'
    $eventA = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskA '.jsonl'
    $eventB = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskB '.jsonl'
    $eventA | Should Not Be $eventB
    Test-Path -LiteralPath $eventA | Should Be $true
    Test-Path -LiteralPath $eventB | Should Be $true
  }

  It 'rejects foreign and stale normal clears without removing the entity' {
    $workspace = Join-Path $TestDrive 'clear-cas\workspace'
    $shared = Join-Path $TestDrive 'clear-cas\shared'
    $taskId = 'task-clear-cas'
    $payload = Join-Path $TestDrive 'clear-cas\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $owner = [pscustomobject]@{ agentId='owner-a'; sessionId='session-a'; platform='codex'; workspace='G:\task-state-tests' }
    $foreign = [pscustomobject]@{ agentId='owner-b'; sessionId='session-b'; platform='codex'; workspace='G:\task-state-tests' }
    Write-TestJson $payload ([pscustomobject]@{ taskId=$taskId; status='active'; value='preserve' })
    (Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared -Owner $owner).exitCode | Should Be 0

    $foreignClear = Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -EntityPath $target -Operation clear -ExpectedRevision 1 -Workspace $workspace -Shared $shared -Owner $foreign
    $foreignClear.exitCode | Should Be 1
    $foreignClear.value.error.Contains('TASK_STATE_OWNER_MISMATCH') | Should Be $true
    Test-Path -LiteralPath $target | Should Be $true

    $staleClear = Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -EntityPath $target -Operation clear -ExpectedRevision 0 -Workspace $workspace -Shared $shared -Owner $owner
    $staleClear.exitCode | Should Be 1
    $staleClear.value.error.Contains('TASK_STATE_CAS_MISMATCH') | Should Be $true
    Test-Path -LiteralPath $target | Should Be $true
  }

  It 'rejects stale concurrent normal writes without appending conflicting revisions' {
    $workspace = Join-Path $TestDrive 'concurrent\workspace'
    $shared = Join-Path $TestDrive 'concurrent\shared'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-concurrent' 'context'
    $workerCount = 6
    $jobs = @()
    try {
      foreach($worker in 1..$workerCount) {
        $payload = Join-Path $TestDrive "concurrent\payload-$worker.json"
        Write-TestJson $payload ([pscustomobject]@{ taskId='task-concurrent'; status='active'; worker=$worker })
        $jobs += Start-Job -ArgumentList $storeScript,$workspace,$shared,$payload,$target,$worker -ScriptBlock {
          param($StoreScript,$Workspace,$Shared,$Payload,$Target,$Worker)
          $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StoreScript -Action Commit -TaskId task-concurrent -EntityKind context -PayloadPath $Payload -EntityPath $Target -ExpectedRevision 0 -OwnerAgentId agent-test -OwnerSessionId session-test -OwnerPlatform codex -OwnerWorkspace 'G:\task-state-tests' -WorkspaceRoot $Workspace -SharedRoot $Shared -Source "concurrent-worker-$Worker" -Json 2>&1)
          [pscustomobject]@{ worker=$Worker; exitCode=$LASTEXITCODE; output=($raw -join "`n") }
        }
      }
      $workers = @($jobs | Wait-Job | Receive-Job)
    } finally {
      if($jobs.Count -gt 0) { $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }
    }

    @($workers | Where-Object { $_.exitCode -eq 0 }).Count | Should Be 1
    @($workers | Where-Object { $_.exitCode -ne 0 }).Count | Should Be ($workerCount - 1)
    @($workers | Where-Object { $_.exitCode -ne 0 -and $_.output.Contains('TASK_STATE_CAS_MISMATCH') }).Count | Should Be ($workerCount - 1)
    $projection = Get-Content -Raw -Encoding UTF8 -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') 'task-concurrent' '.json') | ConvertFrom-Json
    $projection.revision | Should Be 1
    $events = @(Get-Content -Encoding UTF8 -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-concurrent' '.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $events.Count | Should Be 2
    @($events | Where-Object { $_.phase -eq 'prepared' }).Count | Should Be 1
    @($events | Where-Object { $_.phase -eq 'committed' }).Count | Should Be 1
    (Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')).value.incompleteTransactionCount | Should Be 0
  }

  It 'classifies independent task pointers as parallel without merging identities' {
    $workspace = Join-Path $TestDrive 'audit\workspace'
    $shared = Join-Path $TestDrive 'audit\shared'
    $context = Join-Path $TestDrive 'audit\context.json'
    $checkpoint = Join-Path $TestDrive 'audit\checkpoint.json'
    Write-TestJson $context ([pscustomobject]@{ taskId='task-context'; status='active' })
    Write-TestJson $checkpoint ([pscustomobject]@{ taskId='task-checkpoint'; status='active' })
    Write-TestJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{ taskId='task-context'; status='active' })
    Write-TestJson (Join-Path $workspace 'active-checkpoint.json') ([pscustomobject]@{ taskId='task-checkpoint'; status='active' })
    Write-TestJson (Join-Path $workspace 'task-graph.json') ([pscustomobject]@{ taskId='task-legacy-graph'; status='idle' })
    Write-TestJson (Join-Path $workspace 'step-ledger.json') ([pscustomobject]@{ taskId='task-legacy-ledger'; openSteps=@() })
    (Invoke-MaintenanceTaskStateRecord 'task-context' 'context' $context $workspace $shared).exitCode | Should Be 0
    (Invoke-MaintenanceTaskStateRecord 'task-checkpoint' 'checkpoint' $checkpoint $workspace $shared).exitCode | Should Be 0

    $audit = Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $audit.exitCode | Should Be 0
    $audit.value.consistency | Should Be 'parallel'
    $audit.value.merged | Should Be $false
    $audit.value.contextTaskId | Should Be 'task-context'
    $audit.value.checkpointTaskId | Should Be 'task-checkpoint'
    @($audit.value.missingProjectionTaskIds).Count | Should Be 0
    $audit.value.authority | Should Be 'task_state_store_and_workspace_selector'
    $audit.value.automaticContinuationSafe | Should Be $true
    $audit.value.compatibilityPointers.taskGraphTaskId | Should Be 'task-legacy-graph'
    $audit.value.compatibilityPointers.stepLedgerTaskId | Should Be 'task-legacy-ledger'
    $audit.value.compatibilityPointers.divergent | Should Be $true
  }

  It 'keeps same-owner pointer mismatches classified as conflicts' {
    $workspace = Join-Path $TestDrive 'owner-conflict\workspace'
    $shared = Join-Path $TestDrive 'owner-conflict\shared'
    $context = Join-Path $TestDrive 'owner-conflict\context.json'
    $checkpoint = Join-Path $TestDrive 'owner-conflict\checkpoint.json'
    $owner = @{ agentId='agent-1'; sessionId='session-1'; platform='codex'; workspace='G:\work' }
    Write-TestJson $context ([pscustomobject]@{ taskId='task-owner-a'; status='active'; agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace })
    Write-TestJson $checkpoint ([pscustomobject]@{ taskId='task-owner-b'; status='active'; agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace })
    Write-TestJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{ taskId='task-owner-a'; status='active' })
    Write-TestJson (Join-Path $workspace 'active-checkpoint.json') ([pscustomobject]@{ taskId='task-owner-b'; status='active' })
    (Invoke-NormalTaskStateCommit -TaskId 'task-owner-a' -EntityKind context -PayloadPath $context -EntityPath (Get-TestTaskStateTarget $workspace $shared 'task-owner-a' 'context') -ExpectedRevision 0 -Workspace $workspace -Shared $shared -Owner ([pscustomobject]$owner)).exitCode | Should Be 0
    (Invoke-NormalTaskStateCommit -TaskId 'task-owner-b' -EntityKind checkpoint -PayloadPath $checkpoint -EntityPath (Get-TestTaskStateTarget $workspace $shared 'task-owner-b' 'checkpoint') -ExpectedRevision 0 -Workspace $workspace -Shared $shared -Owner ([pscustomobject]$owner)).exitCode | Should Be 0
    $audit = Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $audit.value.consistency | Should Be 'conflict'
    $audit.value.sameOwner | Should Be $true
    $audit.value.conflictingTaskId | Should Be 'task-owner-b'
  }

  It 'archives oversized journals behind a replayable snapshot' {
    $workspace = Join-Path $TestDrive 'compact\workspace'
    $shared = Join-Path $TestDrive 'compact\shared'
    $payload = Join-Path $TestDrive 'compact\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-compact' 'task_card'
    foreach($value in 1..3) {
      Write-TestJson $payload ([pscustomobject]@{ taskId='task-compact'; status='active'; value=$value })
      (Invoke-NormalTaskStateCommit -TaskId 'task-compact' -EntityKind task_card -PayloadPath $payload -EntityPath $target -ExpectedRevision ($value - 1) -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    }
    $compact = Invoke-TaskStateStore @('-Action','Compact','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaxEventsPerTask','4','-MaxBytesPerTask','1048576','-Apply','-Json')
    $compact.exitCode | Should Be 0
    $compact.value.compactedCount | Should Be 1
    @(Get-ChildItem -LiteralPath (Join-Path $workspace ('task-state-store\archive\' + (Get-SuperBrainCanonicalTaskToken 'task-compact'))) -Filter '*.jsonl' -File).Count | Should Be 1
    $activeEvents = @(Get-Content -Encoding UTF8 -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-compact' '.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $activeEvents.Count | Should Be 1
    $activeEvents[0].phase | Should Be 'snapshot'
    Remove-Item -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') 'task-compact' '.json') -Force
    (Invoke-TaskStateStore @('-Action','Rebuild','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')).exitCode | Should Be 0
    (Get-Content -Raw -Encoding UTF8 -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') 'task-compact' '.json') | ConvertFrom-Json).revision | Should Be 3
  }

  It 'never compacts a journal with an incomplete transaction' {
    $workspace = Join-Path $TestDrive 'compact-pending\workspace'
    $shared = Join-Path $TestDrive 'compact-pending\shared'
    $payload = Join-Path $workspace 'task-state-store\staging\task-compact-pending\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-compact-pending' 'context'
    Write-TestJson $payload ([pscustomobject]@{ taskId='task-compact-pending'; status='active'; acceptedGoal='must survive compaction' })
    (Invoke-NormalTaskStateCommit -TaskId 'task-compact-pending' -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    Write-TestJson $payload ([pscustomobject]@{ taskId='task-compact-pending'; status='active'; acceptedGoal='pending update must survive compaction' })
    $failed = Invoke-NormalTaskStateCommit -TaskId 'task-compact-pending' -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 1 -Workspace $workspace -Shared $shared -FaultPoint after_prepare
    $failed.exitCode | Should Be 1
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-compact-pending' '.jsonl'
    $beforeHash = (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash

    $compact = Invoke-TaskStateStore @('-Action','Compact','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaxEventsPerTask','2','-MaxBytesPerTask','1024','-Apply','-Json')
    $compact.exitCode | Should Be 0
    $compact.value.compactedCount | Should Be 0
    $compact.value.blockedCount | Should Be 1
    $compact.value.blocked[0].reason | Should Be 'incomplete_transaction'
    (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash | Should Be $beforeHash
    Test-Path -LiteralPath (Join-Path $workspace ('task-state-store\archive\' + (Get-SuperBrainCanonicalTaskToken 'task-compact-pending'))) | Should Be $false
  }

  It 'runs task-state compaction through the lifecycle ApplySafe cold path' {
    $stateRoot = Join-Path $TestDrive 'lifecycle-state'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $payload = Join-Path $workspace 'input\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-lifecycle' 'task_card'
    foreach($value in 1..3) {
      Write-TestJson $payload ([pscustomobject]@{ taskId='task-lifecycle'; status='active'; value=$value })
      (Invoke-NormalTaskStateCommit -TaskId 'task-lifecycle' -EntityKind task_card -PayloadPath $payload -EntityPath $target -ExpectedRevision ($value - 1) -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    }

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\workspace-lifecycle-manager.ps1') -ApplySafe -TaskStateMaxEventsPerTask 4 -TaskStateMaxBytesPerTask 1048576 -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
    $exitCode | Should Be 0
    $lifecycle = ($raw -join "`n") | ConvertFrom-Json
    $lifecycle.ok | Should Be $true
    $archiveAction = @($lifecycle.actions | Where-Object { $_.type -eq 'task_state_journal' -and $_.action -eq 'archive_and_snapshot' -and $_.applied })
    $archiveAction.Count | Should Be 1
    Test-Path -LiteralPath $archiveAction[0].destination | Should Be $true
    $activeEvents = @(Get-Content -Encoding UTF8 -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-lifecycle' '.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $activeEvents.Count | Should Be 1
    $activeEvents[0].phase | Should Be 'snapshot'
  }

  It 'integrates context checkpoint and task-card writers through the store interface' {
    $package = Join-Path $TestDrive 'integration\package'
    $scripts = Join-Path $package 'scripts'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    foreach ($name in @('common.ps1','task-state-store.ps1','task-link-store.ps1','current-task-context.ps1','checkpoint-writer.ps1','task-register.ps1')) {
      Copy-Item -LiteralPath (Join-Path $root "scripts\$name") -Destination (Join-Path $scripts $name)
    }
    Copy-Item -LiteralPath (Join-Path $root 'manifest.json') -Destination (Join-Path $package 'manifest.json')
    Copy-Item -LiteralPath (Join-Path $root 'memory-policy.json') -Destination (Join-Path $package 'memory-policy.json')

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $package 'memory'
      $contextRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'current-task-context.ps1') -Action Create -TaskId task-context-writer -AcceptedGoal goal -Json 2>$null)
      $contextExitCode = $LASTEXITCODE
      $checkpointRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'checkpoint-writer.ps1') -Action Start -TaskId task-checkpoint-writer -TaskName checkpoint -Json 2>$null)
      $checkpointExitCode = $LASTEXITCODE
      $taskRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'task-register.ps1') -TaskId task-card-writer -TaskName card -Json 2>$null)
      $taskExitCode = $LASTEXITCODE
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
    $contextExitCode | Should Be 0
    $checkpointExitCode | Should Be 0
    $taskExitCode | Should Be 0
    $contextValue = ($contextRaw -join "`n") | ConvertFrom-Json
    $contextValue.agentId | Should Not BeNullOrEmpty
    $contextValue.sessionId | Should Not BeNullOrEmpty
    $contextValue.platform | Should Not BeNullOrEmpty
    $contextValue.workspace | Should Not BeNullOrEmpty
    (($taskRaw -join "`n") | ConvertFrom-Json).taskStateRevision | Should Be 1

    $workspace = Join-Path $package 'memory\workspace'
    $shared = Join-Path $package 'memory\shared'
    $audit = Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $audit.value.consistency | Should Be 'parallel'
    $audit.value.merged | Should Be $false
    foreach ($id in @('task-context-writer','task-checkpoint-writer','task-card-writer')) {
      Test-Path -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $id '.json') | Should Be $true
    }
  }
}
