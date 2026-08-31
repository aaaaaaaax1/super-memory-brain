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

function Import-TestTaskAuthority([string]$TaskId,[string]$WorkspaceKey,[string]$Workspace,[object]$Projection,[string]$CommandId) {
  $stateRoot = Split-Path -Parent $Workspace
  $ownerSessionKey = 'sid-' + (Get-SuperBrainStableHash ($TaskId + '|' + $WorkspaceKey + '|owner') 24)
  $Projection.lifecycle.workspaceKey = $WorkspaceKey
  $Projection.lifecycle.ownerSessionKey = $ownerSessionKey
  if ([string]::IsNullOrWhiteSpace([string]$Projection.lifecycle.planFingerprint)) { $Projection.lifecycle.planFingerprint = 'plan-' + (Get-SuperBrainStableHash ($TaskId + '|' + $WorkspaceKey) 16) }
  if ([int]$Projection.lifecycle.contractRevision -lt 1) { $Projection.lifecycle.contractRevision = 1 }
  $state = [pscustomobject]@{
    lifecycle=[string]$Projection.lifecycle.status; contractRevision=[int]$Projection.lifecycle.contractRevision; planFingerprint=[string]$Projection.lifecycle.planFingerprint
    currentPhase=''; currentStep=''; nextAction=''; completedSteps=@(); pendingSteps=@(); blockers=@(); evidence=@(); verificationResults=@(); constraints=@(); acceptanceCriteria=@()
    entities=$Projection.entities; taskStateRevision=[int]$Projection.revision
  }
  $request = [pscustomobject]@{
    commandId=$CommandId; taskId=$TaskId; taskInstanceId=('ti-' + (Get-SuperBrainStableHash ($TaskId + '|' + $WorkspaceKey + '|instance') 32)); workspaceKey=$WorkspaceKey
    ownerSessionKey=$ownerSessionKey; packageVersion=[string](Get-SuperBrainManifest $root).version; initialRevision=[int]$Projection.revision; source='TaskStateStore.Tests.ps1'; state=$state
  }
  $runtime = Join-Path $root 'runtime\brain_control.py'
  $raw = @($request | ConvertTo-Json -Depth 20 -Compress | & python -B $runtime --state-root $stateRoot import-task 2>&1)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  if ($exitCode -ne 0) { throw "TEST_TASK_AUTHORITY_IMPORT_FAILED $text" }
  return $text | ConvertFrom-Json
}

function Get-TestTaskAuthority([string]$TaskId,[string]$WorkspaceKey,[string]$Workspace) {
  $runtime = Join-Path $root 'runtime\brain_control.py'
  $stateRoot = Split-Path -Parent $Workspace
  $request = [pscustomobject]@{ taskId=$TaskId; workspaceKey=$WorkspaceKey }
  $raw = @($request | ConvertTo-Json -Compress | & python -B $runtime --state-root $stateRoot locate-task 2>&1)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  if ($exitCode -ne 0) { throw "TEST_TASK_AUTHORITY_LOCATE_FAILED $text" }
  return $text | ConvertFrom-Json
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

  It 'does not delete a foreign entity after target drift during a direct clear' {
    $workspace = Join-Path $TestDrive 'direct-clear-drift\workspace'
    $shared = Join-Path $TestDrive 'direct-clear-drift\shared'
    $taskId = 'task-direct-clear-drift'
    $payload = Join-Path $TestDrive 'direct-clear-drift\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    Write-TestJson $payload ([pscustomobject]@{
      taskId = $taskId
      workspaceKey = 'ws-direct-clear-drift'
      status = 'active'
      acceptedGoal = 'retain foreign target on identity drift'
      agentId = $script:DefaultTaskStateOwner.agentId
      sessionId = $script:DefaultTaskStateOwner.sessionId
      platform = $script:DefaultTaskStateOwner.platform
      workspace = $script:DefaultTaskStateOwner.workspace
    })
    $seed = Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared
    $seed.exitCode | Should Be 0
    $foreign = [pscustomobject]@{ taskId = 'task-foreign'; workspaceKey = 'ws-foreign'; status = 'active'; body = 'must survive' }
    Write-TestJson $target $foreign
    $foreignHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash

    $cleared = Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -EntityPath $target -Operation clear -ExpectedRevision 1 -Workspace $workspace -Shared $shared
    $cleared.exitCode | Should Be 1
    $cleared.value.error | Should Match 'TASK_STATE_COMPLETION_DELETE_IDENTITY_MISMATCH'
    (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash | Should Be $foreignHash
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    (Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json).revision | Should Be 1
  }

  It 'withholds prepared direct replay when an external writer changes the materialized target' {
    $workspace = Join-Path $TestDrive 'direct-replay-drift\workspace'
    $shared = Join-Path $TestDrive 'direct-replay-drift\shared'
    $taskId = 'task-direct-replay-drift'
    $payload = Join-Path $workspace 'task-state-store\staging\task-direct-replay-drift\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    Write-TestJson $payload ([pscustomobject]@{
      taskId = $taskId
      workspaceKey = 'ws-direct-replay-drift'
      status = 'active'
      acceptedGoal = 'prepared replay must not overwrite an external writer'
      agentId = $script:DefaultTaskStateOwner.agentId
      sessionId = $script:DefaultTaskStateOwner.sessionId
      platform = $script:DefaultTaskStateOwner.platform
      workspace = $script:DefaultTaskStateOwner.workspace
    })
    $failed = Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared -FaultPoint after_materialize
    $failed.exitCode | Should Be 1
    Test-Path -LiteralPath $target | Should Be $true
    Write-TestJson $target ([pscustomobject]@{ taskId = 'task-external'; workspaceKey = 'ws-external'; status = 'active'; body = 'external writer wins' })
    $externalHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash

    $reconciled = Invoke-TaskStateStore @('-Action','Reconcile','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $reconciled.exitCode | Should Be 1
    $reconciled.value.blockedCount | Should BeGreaterThan 0
    @($reconciled.value.blocked | Where-Object { [string]$_.reason -eq 'target_changed_after_prepare' }).Count | Should BeGreaterThan 0
    (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash | Should Be $externalHash
    $events = @(Get-Content -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    @($events | Where-Object { [string]$_.phase -eq 'committed' }).Count | Should Be 0
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
    $audit.value.sameOwner | Should Be $false
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

  It 'uses the workspace-scoped context and checkpoint as authority while retaining divergent compatibility pointers as diagnostics' {
    $workspace = Join-Path $TestDrive 'scoped-audit\workspace'
    $shared = Join-Path $TestDrive 'scoped-audit\shared'
    $project = Join-Path $TestDrive 'scoped-audit\project-alpha'
    $workspaceKey = Get-SuperBrainWorkspaceKey $project
    $taskId = 'task-scoped-authority'
    $owner = [pscustomobject]@{ agentId='agent-scoped'; sessionId='session-scoped'; platform='codex'; workspace=$project }
    $contextPath = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpointPath = Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint'
    $context = [pscustomobject]@{ taskId=$taskId; status='active'; stale=$false; workspaceKey=$workspaceKey; expiresAt=(Get-Date).AddHours(1).ToString('o'); agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace }
    $checkpoint = [pscustomobject]@{ taskId=$taskId; status='active'; workspaceKey=$workspaceKey; pendingSteps=@('continue'); agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace }
    Write-TestJson $contextPath $context
    Write-TestJson $checkpointPath $checkpoint
    (Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -PayloadPath $contextPath -EntityPath $contextPath -ExpectedRevision 0 -Workspace $workspace -Shared $shared -Owner $owner).exitCode | Should Be 0
    (Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind checkpoint -PayloadPath $checkpointPath -EntityPath $checkpointPath -ExpectedRevision 1 -Workspace $workspace -Shared $shared -Owner $owner).exitCode | Should Be 0

    $pointerRoot = Join-Path $workspace 'guard-state\current-task-context-pointers'
    Write-TestJson (Get-SuperBrainCanonicalTaskPath $pointerRoot $workspaceKey '.json') $context
    Write-TestJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{ taskId='task-legacy-context'; status='active' })
    Write-TestJson (Join-Path $workspace 'active-checkpoint.json') ([pscustomobject]@{ taskId='task-legacy-checkpoint'; status='active' })

    $audit = Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-OwnerWorkspace',$project,'-Json')
    $audit.exitCode | Should Be 0
    $audit.value.contextTaskId | Should Be $taskId
    $audit.value.checkpointTaskId | Should Be $taskId
    $audit.value.consistency | Should Be 'consistent'
    $audit.value.pointerMismatch | Should Be $false
    $audit.value.automaticContinuationTaskId | Should Be $taskId
    $audit.value.workspaceSelection.contextSource | Should Be 'workspace_scoped'
    $audit.value.compatibilityPointers.contextTaskId | Should Be 'task-legacy-context'
    $audit.value.compatibilityPointers.checkpointTaskId | Should Be 'task-legacy-checkpoint'
    $audit.value.compatibilityPointers.divergent | Should Be $true
  }

  It 'refuses to compact a journal when its projection diverges from WAL authority' {
    $workspace = Join-Path $TestDrive 'compact\workspace'
    $shared = Join-Path $TestDrive 'compact\shared'
    $payload = Join-Path $TestDrive 'compact\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-compact' 'task_card'
    foreach($value in 1..3) {
      Write-TestJson $payload ([pscustomobject]@{ taskId='task-compact'; status='active'; value=$value })
      (Invoke-NormalTaskStateCommit -TaskId 'task-compact' -EntityKind task_card -PayloadPath $payload -EntityPath $target -ExpectedRevision ($value - 1) -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    }
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') 'task-compact' '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.lifecycle.status = 'completed'
    Write-TestJson $projectionPath $projection
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-compact' '.jsonl'
    $beforeHash = (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash
    $compact = Invoke-TaskStateStore @('-Action','Compact','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaxEventsPerTask','4','-MaxBytesPerTask','1048576','-Apply','-Json')
    $compact.exitCode | Should Be 0
    $compact.value.compactedCount | Should Be 0
    $compact.value.blockedCount | Should Be 1
    $compact.value.blocked[0].reason | Should Be 'projection_wal_mismatch'
    (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash | Should Be $beforeHash
    Test-Path -LiteralPath (Join-Path $workspace ('task-state-store\archive\' + (Get-SuperBrainCanonicalTaskToken 'task-compact'))) | Should Be $false
  }

  It 'archives an authority-aligned terminal journal behind a replayable snapshot' {
    $stateRoot = Join-Path $TestDrive 'compact-terminal'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $taskId = 'task-compact-terminal'
    $payload = Join-Path $TestDrive 'compact-terminal\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared $taskId 'task_card'
    foreach($value in 1..3) {
      Write-TestJson $payload ([pscustomobject]@{ taskId=$taskId; status='active'; value=$value })
      (Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind task_card -PayloadPath $payload -EntityPath $target -ExpectedRevision ($value - 1) -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    }
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.lifecycle.status = 'archived'
    $projection.entities.task_card.status = 'archived'
    $authority = Import-TestTaskAuthority $taskId 'ws-compact-terminal' $workspace $projection 'task-compact-terminal-import'
    $authority.revision | Should Be 3
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $snapshotEventId = [guid]::NewGuid().ToString('n')
    $projection.lastEventId = $snapshotEventId
    $projection.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $snapshotEvent = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='snapshot'; transactionId=''; eventId=$snapshotEventId; taskId=$taskId; revision=[int]$projection.revision; previousRevision=0; projection=$projection; source='TaskStateStore.Tests.ps1:terminal-authority-fixture'; recordedAt=$projection.updatedAt }
    $eventLines = @()
    $eventLines += @(Get-Content -LiteralPath $eventPath -Encoding UTF8)
    $eventLines += ($snapshotEvent | ConvertTo-Json -Depth 16 -Compress)
    [IO.File]::WriteAllLines($eventPath,[string[]]$eventLines,[Text.UTF8Encoding]::new($false))
    Write-TestJson $projectionPath $projection

    $compact = Invoke-TaskStateStore @('-Action','Compact','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaxEventsPerTask','4','-MaxBytesPerTask','1048576','-Apply','-Json')
    if ($compact.exitCode -ne 0) { throw "COMPACT_TERMINAL_FAILED $($compact.text)" }
    $compact.exitCode | Should Be 0
    $compact.value.compactedCount | Should Be 1
    @(Get-ChildItem -LiteralPath (Join-Path $workspace ('task-state-store\archive\' + (Get-SuperBrainCanonicalTaskToken $taskId))) -Filter '*.jsonl' -File).Count | Should Be 1
    $activeEvents = @(Get-Content -Encoding UTF8 -LiteralPath $eventPath | ForEach-Object { $_ | ConvertFrom-Json })
    $activeEvents.Count | Should Be 1
    $activeEvents[0].phase | Should Be 'snapshot'
    Remove-Item -LiteralPath $projectionPath -Force
    (Invoke-TaskStateStore @('-Action','Rebuild','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')).exitCode | Should Be 0
    $rebuilt = Get-Content -Raw -Encoding UTF8 -LiteralPath $projectionPath | ConvertFrom-Json
    $rebuilt.revision | Should Be 3
    $rebuilt.lifecycle.status | Should Be 'archived'
  }

  It 'refuses to compact a legacy-key authority mismatch instead of treating authority as absent' {
    $stateRoot = Join-Path $TestDrive 'compact-terminal-authority-mismatch'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $taskId = 'task-compact-terminal-authority-mismatch'
    $workspaceKey = 'ws-compact-terminal-authority-mismatch'
    $payload = Join-Path $TestDrive 'compact-terminal-authority-mismatch\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared $taskId 'task_card'
    foreach($value in 1..3) {
      Write-TestJson $payload ([pscustomobject]@{ taskId=$taskId; status='active'; value=$value })
      (Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind task_card -PayloadPath $payload -EntityPath $target -ExpectedRevision ($value - 1) -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    }
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.lifecycle.status = 'archived'
    $projection.lifecycle.workspaceKey = $workspaceKey
    $projection.lifecycle.ownerSessionKey = 'sid-' + (Get-SuperBrainStableHash ($taskId + '|' + $workspaceKey + '|owner') 24)
    $projection.lifecycle.planFingerprint = 'plan-' + (Get-SuperBrainStableHash ($taskId + '|' + $workspaceKey) 16)
    $projection.lifecycle.contractRevision = 1
    $projection.entities.task_card.status = 'archived'
    $authorityProjection = $projection | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $authorityProjection.entities.task_card.hash = ('0' * 64)
    (Import-TestTaskAuthority $taskId $workspaceKey $workspace $authorityProjection 'task-compact-terminal-authority-mismatch-import').revision | Should Be 3
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $snapshotEventId = [guid]::NewGuid().ToString('n')
    $projection.lastEventId = $snapshotEventId
    $projection.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $snapshotEvent = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='snapshot'; transactionId=''; eventId=$snapshotEventId; taskId=$taskId; revision=[int]$projection.revision; previousRevision=0; projection=$projection; source='TaskStateStore.Tests.ps1:terminal-authority-mismatch-fixture'; recordedAt=$projection.updatedAt }
    $eventLines = @()
    $eventLines += @(Get-Content -LiteralPath $eventPath -Encoding UTF8)
    $eventLines += ($snapshotEvent | ConvertTo-Json -Depth 16 -Compress)
    [IO.File]::WriteAllLines($eventPath,[string[]]$eventLines,[Text.UTF8Encoding]::new($false))
    Write-TestJson $projectionPath $projection
    $beforeHash = (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash

    $compact = Invoke-TaskStateStore @('-Action','Compact','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaxEventsPerTask','4','-MaxBytesPerTask','1048576','-Apply','-Json')
    $compact.exitCode | Should Be 0
    $compact.value.compactedCount | Should Be 0
    $compact.value.blockedCount | Should Be 1
    $compact.value.blocked[0].reason | Should Be 'sqlite_authority_mismatch'
    (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash | Should Be $beforeHash
    Test-Path -LiteralPath (Join-Path $workspace ('task-state-store\archive\' + (Get-SuperBrainCanonicalTaskToken $taskId))) | Should Be $false
  }

  It 'rebuilds legacy projections from WAL before moving them byte-for-byte into quarantine' {
    $workspace=Join-Path $TestDrive 'residual-projection\workspace'
    $shared=Join-Path $TestDrive 'residual-projection\shared'
    $taskId='task-residual-projection'
    $payload=Join-Path $TestDrive 'residual-projection\payload.json'
    $target=Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    Write-TestJson $payload ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='preserve projection history'})
    (Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared).exitCode|Should Be 0
    $canonical=Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $legacy=Join-Path (Join-Path $workspace 'task-state-store\projections') ($taskId+'.json')
    Copy-Item -LiteralPath $canonical -Destination $legacy
    $legacyHash=(Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash
    Remove-Item -LiteralPath $canonical -Force

    $preview=Invoke-TaskStateStore @('-Action','ReconcileResiduals','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $preview.exitCode|Should Be 0
    $preview.value.safeCount|Should Be 1
    $preview.value.candidates[0].classification|Should Be 'rebuildable_legacy_projection'

    $applied=Invoke-TaskStateStore @('-Action','ReconcileResiduals','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $applied.exitCode|Should Be 0
    $applied.value.movedCount|Should Be 1
    Test-Path -LiteralPath $canonical|Should Be $true
    Test-Path -LiteralPath $legacy|Should Be $false
    (Get-FileHash -LiteralPath $applied.value.moved[0].destinationPath -Algorithm SHA256).Hash|Should Be $legacyHash
    (Get-Content -LiteralPath $canonical -Raw -Encoding UTF8|ConvertFrom-Json).taskId|Should Be $taskId
    (Get-Content -LiteralPath $applied.value.manifestPath -Raw -Encoding UTF8|ConvertFrom-Json).destructiveDeleteUsed|Should Be $false
  }

  It 'migrates an event-only legacy stream to its canonical name before replay' {
    $workspace=Join-Path $TestDrive 'residual-event-migration\workspace'
    $shared=Join-Path $TestDrive 'residual-event-migration\shared'
    $taskId='task/residual-event-migration'
    $payload=Join-Path $TestDrive 'residual-event-migration\payload.json'
    $target=Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    Write-TestJson $payload ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='migrate event stream without losing replay authority'})
    (Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared).exitCode|Should Be 0
    $eventRoot=Join-Path $workspace 'task-state-store\events'
    $canonical=Get-SuperBrainCanonicalTaskPath $eventRoot $taskId '.jsonl'
    $legacy=Join-Path $eventRoot 'task-residual-event-migration.jsonl'
    $projection=Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $eventHash=(Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash
    Move-Item -LiteralPath $canonical -Destination $legacy
    Remove-Item -LiteralPath $projection -Force

    $preview=Invoke-TaskStateStore @('-Action','ReconcileResiduals','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $preview.exitCode|Should Be 0
    $preview.value.eventMigrateCount|Should Be 1
    $preview.value.eventShadowCount|Should Be 0
    $preview.value.eventCandidates[0].classification|Should Be 'legacy_event_migration'

    $applied=Invoke-TaskStateStore @('-Action','ReconcileResiduals','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $applied.exitCode|Should Be 0
    $applied.value.eventMigratedCount|Should Be 1
    Test-Path -LiteralPath $legacy|Should Be $false
    Test-Path -LiteralPath $canonical|Should Be $true
    (Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash|Should Be $eventHash
    (Get-Content -LiteralPath $projection -Raw -Encoding UTF8|ConvertFrom-Json).revision|Should Be 1
    $manifest=Get-Content -LiteralPath $applied.value.manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    @($manifest.eventMigrations).Count|Should Be 1
    $manifest.destructiveDeleteUsed|Should Be $false
  }

  It 'quarantines a newer legacy event shadow without changing canonical replay' {
    $workspace=Join-Path $TestDrive 'residual-event-shadow\workspace'
    $shared=Join-Path $TestDrive 'residual-event-shadow\shared'
    $taskId='task/residual-event-shadow'
    $payload=Join-Path $TestDrive 'residual-event-shadow\payload.json'
    $target=Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    Write-TestJson $payload ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='canonical stream must remain authoritative'})
    (Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -PayloadPath $payload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared).exitCode|Should Be 0
    $eventRoot=Join-Path $workspace 'task-state-store\events'
    $canonical=Get-SuperBrainCanonicalTaskPath $eventRoot $taskId '.jsonl'
    $legacy=Join-Path $eventRoot 'task-residual-event-shadow.jsonl'
    $canonicalHash=(Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash
    $shadowEvent=(Get-Content -LiteralPath $canonical -Encoding UTF8|Select-Object -First 1|ConvertFrom-Json)
    $shadowEvent.eventId='shadow-event-must-not-win'
    $shadowEvent.source='legacy-shadow-regression'
    [IO.File]::WriteAllText($legacy,($shadowEvent|ConvertTo-Json -Depth 12 -Compress)+"`r`n",[Text.UTF8Encoding]::new($false))
    $shadowHash=(Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash

    $preview=Invoke-TaskStateStore @('-Action','ReconcileResiduals','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $preview.exitCode|Should Be 0
    $preview.value.eventMigrateCount|Should Be 0
    $preview.value.eventShadowCount|Should Be 1
    $preview.value.eventCandidates[0].classification|Should Be 'legacy_event_shadow'

    $applied=Invoke-TaskStateStore @('-Action','ReconcileResiduals','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $applied.exitCode|Should Be 0
    $applied.value.eventQuarantinedCount|Should Be 1
    Test-Path -LiteralPath $legacy|Should Be $false
    (Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash|Should Be $canonicalHash
    (Get-FileHash -LiteralPath $applied.value.eventQuarantines[0].destinationPath -Algorithm SHA256).Hash|Should Be $shadowHash
    $projection=Get-Content -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $projection.lastEventId|Should Not Be 'shadow-event-must-not-win'
    $manifest=Get-Content -LiteralPath $applied.value.manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    @($manifest.eventQuarantines).Count|Should Be 1
    $manifest.destructiveDeleteUsed|Should Be $false
  }

  It 'quarantines conflicting completion evidence using current hashes without inferring completion' {
    $workspace=Join-Path $TestDrive 'ambiguous-conflict\workspace'
    $shared=Join-Path $TestDrive 'ambiguous-conflict\shared'
    $taskId='task/ambiguous-conflict'
    $context=Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpoint=Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint' 'completed'
    $taskCard=Get-TestTaskStateTarget $workspace $shared $taskId 'task_card' 'completed'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='ambiguous legacy state'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 1).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'task_card' $taskCard $workspace $shared 2).exitCode|Should Be 0

    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='ambiguous legacy state';postProjectionMutation='context'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@();postProjectionMutation='checkpoint'})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@();postProjectionMutation='task-card'})
    $legacyContext=Join-Path (Split-Path -Parent $context) 'task-ambiguous-conflict.json'
    $legacyCheckpoint=Join-Path (Split-Path -Parent $checkpoint) 'task-ambiguous-conflict.json'
    $legacyTaskCard=Join-Path (Split-Path -Parent $taskCard) 'task-ambiguous-conflict.task.json'
    Move-Item -LiteralPath $context -Destination $legacyContext
    Move-Item -LiteralPath $checkpoint -Destination $legacyCheckpoint
    Move-Item -LiteralPath $taskCard -Destination $legacyTaskCard
    $currentHashes=@((Get-FileHash -LiteralPath $legacyContext -Algorithm SHA256).Hash,(Get-FileHash -LiteralPath $legacyCheckpoint -Algorithm SHA256).Hash,(Get-FileHash -LiteralPath $legacyTaskCard -Algorithm SHA256).Hash)

    $preview=Invoke-TaskStateStore @('-Action','ReconcileAmbiguousState','-TaskId',$taskId,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $preview.exitCode|Should Be 0
    $preview.value.candidateCount|Should Be 1
    $preview.value.safeCount|Should Be 1
    $preview.value.completionConflictCount|Should Be 1
    $preview.value.candidates[0].sourceCount|Should Be 3

    $applied=Invoke-TaskStateStore @('-Action','ReconcileAmbiguousState','-TaskId',$taskId,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Source','TaskStateStore.Tests.ps1','-Json')
    if ($applied.exitCode -ne 0) { throw "AMBIGUOUS_APPLY_FAILED $($applied.text)" }
    $applied.exitCode|Should Be 0
    $applied.value.quarantinedCount|Should Be 1
    $projectionPath=Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection=Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8|ConvertFrom-Json
    $projection.lifecycle.status|Should Be 'quarantined'
    $projection.lifecycle.completionTransactionId|Should Be ''
    $projection.lifecycle.quarantineReason|Should Be 'completion_evidence_conflict'
    @($projection.entities.context.status,$projection.entities.checkpoint.status,$projection.entities.task_card.status)|Should Be @('quarantined','quarantined','quarantined')
    Test-Path -LiteralPath $legacyContext|Should Be $false
    Test-Path -LiteralPath $legacyCheckpoint|Should Be $false
    Test-Path -LiteralPath $legacyTaskCard|Should Be $false
    @((Get-FileHash -LiteralPath $projection.entities.context.path -Algorithm SHA256).Hash,(Get-FileHash -LiteralPath $projection.entities.checkpoint.path -Algorithm SHA256).Hash,(Get-FileHash -LiteralPath $projection.entities.task_card.path -Algorithm SHA256).Hash)|Should Be $currentHashes
    $manifest=Get-Content -LiteralPath $projection.lifecycle.quarantineManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    $manifest.completionInferred|Should Be $false
    $manifest.destructiveDeleteUsed|Should Be $false
    Remove-Item -LiteralPath $projectionPath -Force
    (Invoke-TaskStateStore @('-Action','Rebuild','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')).exitCode|Should Be 0
    (Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8|ConvertFrom-Json).lifecycle.status|Should Be 'quarantined'
  }

  It 'binds legacy raw workspace authority during ambiguous-state quarantine' {
    $workspace=Join-Path $TestDrive 'ambiguous-legacy-authority\workspace'
    $shared=Join-Path $TestDrive 'ambiguous-legacy-authority\shared'
    $taskId='task-ambiguous-legacy-authority'
    $legacyWorkspaceKey='ws-ambiguous-legacy-authority'
    $context=Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpoint=Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint' 'completed'
    $taskCard=Get-TestTaskStateTarget $workspace $shared $taskId 'task_card' 'completed'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='bind legacy authority'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 1).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'task_card' $taskCard $workspace $shared 2).exitCode|Should Be 0

    $projectionPath=Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection=Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8|ConvertFrom-Json
    $authority=Import-TestTaskAuthority $taskId $legacyWorkspaceKey $workspace $projection 'task-ambiguous-legacy-authority-import'
    $authority.revision|Should Be 3
    Write-TestJson $projectionPath $projection

    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='bind legacy authority';postProjectionMutation='context'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@();postProjectionMutation='checkpoint'})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@();postProjectionMutation='task-card'})
    $legacyContext=Join-Path (Split-Path -Parent $context) 'task-ambiguous-legacy-authority.json'
    $legacyCheckpoint=Join-Path (Split-Path -Parent $checkpoint) 'task-ambiguous-legacy-authority.json'
    $legacyTaskCard=Join-Path (Split-Path -Parent $taskCard) 'task-ambiguous-legacy-authority.task.json'
    Move-Item -LiteralPath $context -Destination $legacyContext
    Move-Item -LiteralPath $checkpoint -Destination $legacyCheckpoint
    Move-Item -LiteralPath $taskCard -Destination $legacyTaskCard

    $applied=Invoke-TaskStateStore @('-Action','ReconcileAmbiguousState','-TaskId',$taskId,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Source','TaskStateStore.Tests.ps1','-Json')
    if ($applied.exitCode -ne 0) { throw "AMBIGUOUS_LEGACY_AUTHORITY_APPLY_FAILED $($applied.text)" }
    $applied.value.quarantinedCount|Should Be 1
    $updated=Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8|ConvertFrom-Json
    $updated.lifecycle.status|Should Be 'quarantined'
    $updated.lifecycle.authorityAggregateId|Should Be $authority.aggregateId
    $updated.lifecycle.authorityRevision|Should Be 4
    (Get-TestTaskAuthority $taskId $legacyWorkspaceKey $workspace).revision|Should Be 4
  }

  It 'quarantines missing ambiguous evidence as lost authority without fabricating files' {
    $workspace=Join-Path $TestDrive 'ambiguous-missing\workspace'
    $shared=Join-Path $TestDrive 'ambiguous-missing\shared'
    $taskId='task-ambiguous-missing'
    $context=Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpoint=Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint' 'completed'
    $taskCard=Get-TestTaskStateTarget $workspace $shared $taskId 'task_card' 'completed'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 1).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'task_card' $taskCard $workspace $shared 2).exitCode|Should Be 0
    Remove-Item -LiteralPath $context,$checkpoint,$taskCard -Force

    $preview=Invoke-TaskStateStore @('-Action','ReconcileAmbiguousState','-TaskId',$taskId,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $preview.exitCode|Should Be 0
    $preview.value.safeCount|Should Be 1
    $preview.value.candidates[0].sourceCount|Should Be 0
    $applied=Invoke-TaskStateStore @('-Action','ReconcileAmbiguousState','-TaskId',$taskId,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    if ($applied.exitCode -ne 0) { throw "AMBIGUOUS_APPLY_FAILED $($applied.text)" }
    $applied.exitCode|Should Be 0
    $projection=Get-Content -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $projection.lifecycle.status|Should Be 'quarantined'
    $projection.entities.context|Should Be $null
    $projection.entities.checkpoint|Should Be $null
    $projection.entities.task_card|Should Be $null
    $manifest=Get-Content -LiteralPath $projection.lifecycle.quarantineManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    @($manifest.entities|Where-Object{$_.currentExists}).Count|Should Be 0
    $manifest.completionInferred|Should Be $false
  }

  It 'recovers an interrupted ambiguous-state quarantine from its prepared WAL event' {
    $workspace=Join-Path $TestDrive 'ambiguous-recovery\workspace'
    $shared=Join-Path $TestDrive 'ambiguous-recovery\shared'
    $taskId='task-ambiguous-recovery'
    $context=Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpoint=Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint' 'completed'
    $taskCard=Get-TestTaskStateTarget $workspace $shared $taskId 'task_card' 'completed'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 1).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'task_card' $taskCard $workspace $shared 2).exitCode|Should Be 0

    $failed=Invoke-TaskStateStore @('-Action','ReconcileAmbiguousState','-TaskId',$taskId,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-FaultAfterMaterialization','2','-Json')
    $failed.exitCode|Should Be 1
    (Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')).value.incompleteTransactionCount|Should Be 1
    $writerBlocked=Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 3
    $writerBlocked.exitCode|Should Be 1
    $writerBlocked.value.error|Should Match 'PENDING_TRANSACTION_REQUIRES_RECONCILE'
    $recovered=Invoke-TaskStateStore @('-Action','Reconcile','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    if ($recovered.exitCode -ne 0) { throw "AMBIGUOUS_RECOVERY_FAILED $($recovered.text)" }
    $recovered.exitCode|Should Be 0
    $recovered.value.recoveredCount|Should Be 1
    (Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')).value.incompleteTransactionCount|Should Be 0
    $projection=Get-Content -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $projection.lifecycle.status|Should Be 'quarantined'
    Test-Path -LiteralPath $projection.lifecycle.quarantineManifestPath|Should Be $true
    Test-Path -LiteralPath $context|Should Be $false
    Test-Path -LiteralPath $checkpoint|Should Be $false
    Test-Path -LiteralPath $taskCard|Should Be $false
  }

  It 'blocks ambiguous-state quarantine while another active wake surface references the task' {
    $workspace=Join-Path $TestDrive 'ambiguous-referenced\workspace'
    $shared=Join-Path $TestDrive 'ambiguous-referenced\shared'
    $taskId='task-ambiguous-referenced'
    $context=Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpoint=Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint' 'completed'
    $taskCard=Get-TestTaskStateTarget $workspace $shared $taskId 'task_card' 'completed'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 1).exitCode|Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'task_card' $taskCard $workspace $shared 2).exitCode|Should Be 0
    $compatibilityPointer=Join-Path $workspace 'current-task-context.json'
    Write-TestJson $compatibilityPointer ([pscustomobject]@{taskId=$taskId;status='active'})

    $preview=Invoke-TaskStateStore @('-Action','ReconcileAmbiguousState','-TaskId',$taskId,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')
    $preview.exitCode|Should Be 0
    $preview.value.blockedCount|Should Be 1
    (@($preview.value.candidates[0].errors) -contains 'external_wake_reference_present')|Should Be $true
    $blocked=Invoke-TaskStateStore @('-Action','ReconcileAmbiguousState','-TaskId',$taskId,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $blocked.exitCode|Should Be 1
    $blocked.value.applied|Should Be $false
    Test-Path -LiteralPath $context|Should Be $true
    Test-Path -LiteralPath $checkpoint|Should Be $true
    Test-Path -LiteralPath $taskCard|Should Be $true
  }

  It 'quarantines independently safe tasks while preserving a preflight-blocked task' {
    $workspace=Join-Path $TestDrive 'ambiguous-mixed\workspace'
    $shared=Join-Path $TestDrive 'ambiguous-mixed\shared'
    $safeTask='task-ambiguous-safe'
    $blockedTask='task-ambiguous-blocked'
    function New-AmbiguousFixture([string]$Id) {
      $context=Get-TestTaskStateTarget $workspace $shared $Id 'context'
      $checkpoint=Get-TestTaskStateTarget $workspace $shared $Id 'checkpoint' 'completed'
      $taskCard=Get-TestTaskStateTarget $workspace $shared $Id 'task_card' 'completed'
      Write-TestJson $context ([pscustomobject]@{taskId=$Id;status='active'})
      Write-TestJson $checkpoint ([pscustomobject]@{taskId=$Id;status='completed';pendingSteps=@()})
      Write-TestJson $taskCard ([pscustomobject]@{taskId=$Id;status='completed';pendingSteps=@()})
      (Invoke-MaintenanceTaskStateRecord $Id 'context' $context $workspace $shared 0).exitCode|Should Be 0
      (Invoke-MaintenanceTaskStateRecord $Id 'checkpoint' $checkpoint $workspace $shared 1).exitCode|Should Be 0
      (Invoke-MaintenanceTaskStateRecord $Id 'task_card' $taskCard $workspace $shared 2).exitCode|Should Be 0
      return [pscustomobject]@{context=$context;checkpoint=$checkpoint;taskCard=$taskCard}
    }
    $safe=New-AmbiguousFixture $safeTask
    $blocked=New-AmbiguousFixture $blockedTask
    Write-TestJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{taskId=$blockedTask;status='active'})

    $applied=Invoke-TaskStateStore @('-Action','ReconcileAmbiguousState','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $applied.exitCode|Should Be 1
    $applied.value.applied|Should Be $true
    $applied.value.quarantinedCount|Should Be 1
    $applied.value.blockedCount|Should Be 1
    (Get-Content -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $safeTask '.json') -Raw -Encoding UTF8|ConvertFrom-Json).lifecycle.status|Should Be 'quarantined'
    Test-Path -LiteralPath $blocked.context|Should Be $true
    Test-Path -LiteralPath $blocked.checkpoint|Should Be $true
    Test-Path -LiteralPath $blocked.taskCard|Should Be $true
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

  It 'never compacts an active journal without an incomplete transaction' {
    $workspace = Join-Path $TestDrive 'compact-active\workspace'
    $shared = Join-Path $TestDrive 'compact-active\shared'
    $payload = Join-Path $workspace 'input\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-compact-active' 'task_card'
    foreach($value in 1..3) {
      Write-TestJson $payload ([pscustomobject]@{ taskId='task-compact-active'; status='active'; value=$value })
      (Invoke-NormalTaskStateCommit -TaskId 'task-compact-active' -EntityKind task_card -PayloadPath $payload -EntityPath $target -ExpectedRevision ($value - 1) -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    }
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-compact-active' '.jsonl'
    $beforeHash = (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash

    $compact = Invoke-TaskStateStore @('-Action','Compact','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaxEventsPerTask','2','-MaxBytesPerTask','1024','-Apply','-Json')
    $compact.exitCode | Should Be 0
    $compact.value.compactedCount | Should Be 0
    $compact.value.blockedCount | Should Be 1
    $compact.value.blocked[0].reason | Should Be 'active_or_unresolved_lifecycle'
    (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash | Should Be $beforeHash
  }

  It 'refuses lifecycle ApplySafe compaction when a projection diverges from WAL authority' {
    $stateRoot = Join-Path $TestDrive 'lifecycle-state'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $payload = Join-Path $workspace 'input\payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared 'task-lifecycle' 'task_card'
    foreach($value in 1..3) {
      Write-TestJson $payload ([pscustomobject]@{ taskId='task-lifecycle'; status='active'; value=$value })
      (Invoke-NormalTaskStateCommit -TaskId 'task-lifecycle' -EntityKind task_card -PayloadPath $payload -EntityPath $target -ExpectedRevision ($value - 1) -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    }
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') 'task-lifecycle' '.json'
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') 'task-lifecycle' '.jsonl'
    $beforeEventHash = (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.lifecycle.status = 'completed'
    Write-TestJson $projectionPath $projection

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\workspace-lifecycle-manager.ps1') -ApplySafe -TaskStateMaxEventsPerTask 4 -TaskStateMaxBytesPerTask 1048576 -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
    $exitCode | Should Be 1
    $lifecycle = ($raw -join "`n") | ConvertFrom-Json
    $lifecycle.ok | Should Be $false
    $lifecycle.errorCount | Should Be 1
    $failedAction = @($lifecycle.actions | Where-Object { $_.type -eq 'task_state_store' -and $_.action -eq 'maintenance_failed' })
    $failedAction.Count | Should Be 1
    $lifecycle.errors[0].where | Should Be 'task_state_maintenance'
    $lifecycle.errors[0].message.Contains('TASK_STATE_STORE_SYNC_FAILED') | Should Be $true
    (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash | Should Be $beforeEventHash
    $activeEvents = @(Get-Content -Encoding UTF8 -LiteralPath $eventPath | ForEach-Object { $_ | ConvertFrom-Json })
    $activeEvents.Count | Should Be 6
    @($activeEvents | Where-Object { $_.phase -eq 'snapshot' }).Count | Should Be 0
  }

  It 'integrates context checkpoint and task-card writers through the store interface' {
    $package = Join-Path $TestDrive 'integration\package'
    $scripts = Join-Path $package 'scripts'
    $runtime = Join-Path $package 'runtime'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $scripts 'internal') | Out-Null
    foreach ($name in @('common.ps1','task-state-store.ps1','task-link-store.ps1','current-task-context.ps1','checkpoint-writer.ps1','task-register.ps1')) {
      Copy-Item -LiteralPath (Join-Path $root "scripts\$name") -Destination (Join-Path $scripts $name)
    }
    Copy-Item -LiteralPath (Join-Path $root 'scripts\internal\phase-closeout-core.ps1') -Destination (Join-Path $scripts 'internal\phase-closeout-core.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'manifest.json') -Destination (Join-Path $package 'manifest.json')
    Copy-Item -LiteralPath (Join-Path $root 'memory-policy.json') -Destination (Join-Path $package 'memory-policy.json')
    # brain_control imports the package-owned context helper directly; keep
    # the isolated integration fixture representative of the supported runtime
    # bundle instead of accidentally testing a missing dependency.
    foreach ($name in @('brain_control.py','brain_context.py','migration_control.py','memory_consolidation.py')) {
      Copy-Item -LiteralPath (Join-Path $root "runtime\$name") -Destination (Join-Path $runtime $name)
    }

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
    $audit.value.consistency | Should Be 'conflict'
    $audit.value.sameOwner | Should Be $true
    $audit.value.merged | Should Be $false
    foreach ($id in @('task-context-writer','task-checkpoint-writer','task-card-writer')) {
      Test-Path -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $id '.json') | Should Be $true
    }
  }

  It 'rebinds hash-verified active projections from a retired state root without changing lifecycle authority' {
    $legacyRoot = Join-Path $TestDrive 'retired-state-root'
    $workspace = Join-Path $TestDrive 'private-state\workspace'
    $shared = Join-Path $TestDrive 'private-state\shared'
    $taskId = 'task-projection-path-rebind'
    $context = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpoint = Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint' 'active'
    $taskCard = Get-TestTaskStateTarget $workspace $shared $taskId 'task_card' 'active'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='preserve active task'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='active';pendingSteps=@('rebind projection')})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='active';pendingSteps=@('rebind projection')})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode | Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 1).exitCode | Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'task_card' $taskCard $workspace $shared 2).exitCode | Should Be 0

    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.entities.context.path = Join-Path (Join-Path $legacyRoot 'workspace') $context.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $projection.entities.checkpoint.path = Join-Path (Join-Path $legacyRoot 'workspace') $checkpoint.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $projection.entities.task_card.path = Join-Path (Join-Path $legacyRoot 'shared') $taskCard.Substring($shared.Length).TrimStart([char[]]@('\','/'))
    Write-TestJson $projectionPath $projection
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $legacyPaths = @{ context=[string]$projection.entities.context.path; checkpoint=[string]$projection.entities.checkpoint.path; task_card=[string]$projection.entities.task_card.path }
    $events = @(Get-Content -LiteralPath $eventPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($event in $events) { if ($event.entityKind -and $event.entity -and $legacyPaths.ContainsKey([string]$event.entityKind)) { $event.entity.path = $legacyPaths[[string]$event.entityKind] } }
    [IO.File]::WriteAllLines($eventPath,@($events | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }),[Text.UTF8Encoding]::new($false))
    $beforeEventCount = @(Get-Content -LiteralPath $eventPath -Encoding UTF8).Count

    $preview = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','hash verified root migration regression','-Json')
    $preview.exitCode | Should Be 0
    $preview.value.applied | Should Be $false
    $preview.value.readyCount | Should Be 3
    $preview.value.blockedCount | Should Be 0
    $preview.value.storeParity.ok | Should Be $true
    (Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json).entities.context.path | Should Match 'retired-state-root'

    $staleApply = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','hash verified root migration regression','-ExpectedPlanFingerprint','stale','-Apply','-Json')
    $staleApply.exitCode | Should Be 1
    @(Get-Content -LiteralPath $eventPath -Encoding UTF8).Count | Should Be $beforeEventCount

    $applied = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','hash verified root migration regression','-ExpectedPlanFingerprint',[string]$preview.value.planFingerprint,'-Apply','-Json')
    if ($applied.exitCode -ne 0) { throw "REBIND_APPLY_FAILED $($applied.text)" }
    $applied.value.reboundCount | Should Be 3
    $applied.value.failureCount | Should Be 0
    Test-Path -LiteralPath $applied.value.receiptPath | Should Be $true
    (Get-Content -LiteralPath $applied.value.receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should Be 'committed'
    @(Get-Content -LiteralPath $eventPath -Encoding UTF8).Count | Should Be ($beforeEventCount + 2)

    $rebound = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rebound.lifecycle.status | Should Be 'active'
    $rebound.entities.context.path | Should Be $context
    $rebound.entities.checkpoint.path | Should Be $checkpoint
    $rebound.entities.task_card.path | Should Be $taskCard
    (Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')).value.projectionParity.ok | Should Be $true
    Remove-Item -LiteralPath $projectionPath -Force
    (Invoke-TaskStateStore @('-Action','Rebuild','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')).exitCode | Should Be 0
    $rebuilt = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rebuilt.entities.context.path | Should Be $context
    $rebuilt.entities.checkpoint.path | Should Be $checkpoint
    $rebuilt.entities.task_card.path | Should Be $taskCard
  }

  It 'keeps an authority-backed projection rebind in lockstep with SQLite' {
    $legacyRoot = Join-Path $TestDrive 'retired-state-root-sqlite'
    $workspace = Join-Path $TestDrive 'private-state-sqlite\workspace'
    $shared = Join-Path $TestDrive 'private-state-sqlite\shared'
    $taskId = 'task-projection-path-rebind-sqlite'
    $workspaceKey = 'ws-projection-path-rebind-sqlite'
    $context = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpoint = Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint' 'active'
    $taskCard = Get-TestTaskStateTarget $workspace $shared $taskId 'task_card' 'active'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceKey;status='active';acceptedGoal='keep rebind canonical'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceKey;status='active';pendingSteps=@('rebind projection')})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceKey;status='active';pendingSteps=@('rebind projection')})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode | Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 1).exitCode | Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'task_card' $taskCard $workspace $shared 2).exitCode | Should Be 0

    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.entities.context.path = Join-Path (Join-Path $legacyRoot 'workspace') $context.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $projection.entities.checkpoint.path = Join-Path (Join-Path $legacyRoot 'workspace') $checkpoint.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $projection.entities.task_card.path = Join-Path (Join-Path $legacyRoot 'shared') $taskCard.Substring($shared.Length).TrimStart([char[]]@('\','/'))
    $authority = Import-TestTaskAuthority $taskId $workspaceKey $workspace $projection 'task-rebind-sqlite-import'
    $authority.revision | Should Be 3
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $snapshotEventId = [guid]::NewGuid().ToString('n')
    $projection.lastEventId = $snapshotEventId
    $projection.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $snapshotEvent = [pscustomobject]@{schema='super-brain.task-state-event.v2';phase='snapshot';transactionId='';eventId=$snapshotEventId;taskId=$taskId;revision=[int]$projection.revision;previousRevision=0;projection=$projection;source='TaskStateStore.Tests.ps1:sqlite-rebind-fixture';recordedAt=$projection.updatedAt}
    $eventLines=@();$eventLines+=@(Get-Content -LiteralPath $eventPath -Encoding UTF8);$eventLines+=($snapshotEvent|ConvertTo-Json -Depth 16 -Compress);[IO.File]::WriteAllLines($eventPath,[string[]]$eventLines,[Text.UTF8Encoding]::new($false))
    Write-TestJson $projectionPath $projection

    $preview = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','sqlite authority rebind regression','-Json')
    $preview.exitCode | Should Be 0
    $applied = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','sqlite authority rebind regression','-ExpectedPlanFingerprint',[string]$preview.value.planFingerprint,'-Apply','-Json')
    $applied.exitCode | Should Be 0
    $applied.value.authorityMode | Should Be 'sqlite'
    $applied.value.authorityRevision | Should Be 4
    $located = Get-TestTaskAuthority $taskId $workspaceKey $workspace
    $located.revision | Should Be 4
    $located.state.entities.context.path | Should Be $context
    $located.state.entities.checkpoint.path | Should Be $checkpoint
    $located.state.entities.task_card.path | Should Be $taskCard
  }

  It 'refuses Record and Import when SQLite authority already owns the task' {
    $stateRoot = Join-Path $TestDrive 'record-authority'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $taskId = 'task-record-authority'
    $workspaceKey = 'ws-record-authority'
    $context = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceKey;status='active';acceptedGoal='initial authority value'})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode | Should Be 0
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $authority = Import-TestTaskAuthority $taskId $workspaceKey $workspace $projection 'task-record-authority-import'
    $authority.revision | Should Be 1
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $snapshotEventId=[guid]::NewGuid().ToString('n');$projection.lastEventId=$snapshotEventId;$projection.updatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $snapshotEvent=[pscustomobject]@{schema='super-brain.task-state-event.v2';phase='snapshot';transactionId='';eventId=$snapshotEventId;taskId=$taskId;revision=[int]$projection.revision;previousRevision=0;projection=$projection;source='TaskStateStore.Tests.ps1:record-authority-fixture';recordedAt=$projection.updatedAt}
    $eventLines=@();$eventLines+=@(Get-Content -LiteralPath $eventPath -Encoding UTF8);$eventLines+=($snapshotEvent|ConvertTo-Json -Depth 16 -Compress);[IO.File]::WriteAllLines($eventPath,[string[]]$eventLines,[Text.UTF8Encoding]::new($false));Write-TestJson $projectionPath $projection
    $beforeEventHash=(Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceKey;status='active';acceptedGoal='attempted overwrite'})
    $record = Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 1
    $record.exitCode | Should Be 1
    $record.value.error | Should Match 'TASK_STATE_RECORD_CANONICAL_AUTHORITY_EXISTS_USE_COMMIT'
    $import = Invoke-TaskStateStore @('-Action','Import','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    $import.exitCode | Should Be 1
    $import.value.invalid[0].reason | Should Be 'sqlite_authority_conflict'
    (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash | Should Be $beforeEventHash
  }

  It 'fails closed without file writes when the SQLite authority runtime is unavailable' {
    $package = Join-Path $TestDrive 'authority-unavailable\package'
    $scripts = Join-Path $package 'scripts'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $scripts 'internal') | Out-Null
    foreach($name in @('common.ps1','task-state-store.ps1')) { Copy-Item -LiteralPath (Join-Path $root ('scripts\' + $name)) -Destination (Join-Path $scripts $name) }
    Copy-Item -LiteralPath (Join-Path $root 'scripts\internal\phase-closeout-core.ps1') -Destination (Join-Path $scripts 'internal\phase-closeout-core.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'manifest.json') -Destination (Join-Path $package 'manifest.json')
    $workspace = Join-Path $package 'memory\workspace'
    $shared = Join-Path $package 'memory\shared'
    $taskId = 'task-authority-unavailable'
    $payload = Join-Path $package 'payload.json'
    $target = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    Write-TestJson $payload ([pscustomobject]@{taskId=$taskId;workspaceKey='ws-authority-unavailable';status='active';acceptedGoal='must not write without authority'})
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'task-state-store.ps1') -Action Commit -TaskId $taskId -EntityKind context -Operation upsert -EntityPath $target -PayloadPath $payload -ExpectedRevision 0 -WorkspaceRoot $workspace -SharedRoot $shared -MaintenanceOverride -MaintenanceReason 'unavailable authority regression' -Json 2>$null)
    $exitCode = $LASTEXITCODE
    $result = ($raw -join "`n") | ConvertFrom-Json
    $exitCode | Should Be 1
    $result.error | Should Match 'TASK_STATE_SQLITE_AUTHORITY_LOCATE_FAILED code=TASK_STATE_SQLITE_AUTHORITY_UNAVAILABLE'
    Test-Path -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl') | Should Be $false
    Test-Path -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json') | Should Be $false
  }

  It 'does not let maintenance override submit a terminal entity through Commit' {
    $workspace = Join-Path $TestDrive 'terminal-maintenance\workspace'
    $shared = Join-Path $TestDrive 'terminal-maintenance\shared'
    $taskId = 'task-terminal-maintenance'
    $activePayload = Join-Path $TestDrive 'terminal-maintenance\active.json'
    $terminalPayload = Join-Path $TestDrive 'terminal-maintenance\terminal.json'
    $target = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    Write-TestJson $activePayload ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='active first'})
    (Invoke-NormalTaskStateCommit -TaskId $taskId -EntityKind context -PayloadPath $activePayload -EntityPath $target -ExpectedRevision 0 -Workspace $workspace -Shared $shared).exitCode | Should Be 0
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $beforeHash = (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash
    Write-TestJson $terminalPayload ([pscustomobject]@{taskId=$taskId;status='completed';acceptedGoal='must require completion transaction'})
    $terminal = Invoke-TaskStateStore @('-Action','Commit','-TaskId',$taskId,'-EntityKind','context','-Operation','upsert','-EntityPath',$target,'-PayloadPath',$terminalPayload,'-ExpectedRevision','1','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','terminal bypass regression','-Json')
    $terminal.exitCode | Should Be 1
    $terminal.value.error | Should Match 'TASK_STATE_COMPLETION_TRANSACTION_REQUIRED'
    (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash | Should Be $beforeHash
  }

  It 'fails closed without writing when a legacy projection target no longer matches its recorded hash' {
    $legacyRoot = Join-Path $TestDrive 'retired-state-root-mismatch'
    $workspace = Join-Path $TestDrive 'private-state-mismatch\workspace'
    $shared = Join-Path $TestDrive 'private-state-mismatch\shared'
    $taskId = 'task-projection-path-rebind-mismatch'
    $context = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='must not rebind stale bytes'})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode | Should Be 0
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.entities.context.path = Join-Path (Join-Path $legacyRoot 'workspace') $context.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    Write-TestJson $projectionPath $projection
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='target bytes changed after projection'})
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $events = @(Get-Content -LiteralPath $eventPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($event in $events) { if ($event.entityKind -eq 'context' -and $event.entity) { $event.entity.path = [string]$projection.entities.context.path } }
    [IO.File]::WriteAllLines($eventPath,@($events | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }),[Text.UTF8Encoding]::new($false))
    $beforeEventCount = @(Get-Content -LiteralPath $eventPath -Encoding UTF8).Count

    $preview = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','fail closed on stale rebind target','-Json')
    $preview.exitCode | Should Be 1
    $preview.value.readyCount | Should Be 0
    $preview.value.blockedCount | Should Be 1
    $preview.value.blocked[0].reason | Should Be 'rebind_materialization_source_hash_mismatch'

    $apply = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','fail closed on stale rebind target','-ExpectedPlanFingerprint',[string]$preview.value.planFingerprint,'-Apply','-Json')
    $apply.exitCode | Should Be 1
    $apply.value.applied | Should Be $false
    @(Get-Content -LiteralPath $eventPath -Encoding UTF8).Count | Should Be $beforeEventCount
    (Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json).entities.context.path | Should Match 'retired-state-root-mismatch'
  }

  It 'materializes a strict canonical target from a hash-verified current legacy filename' {
    $legacyRoot = Join-Path $TestDrive 'retired-state-root-canonicalization'
    $workspace = Join-Path $TestDrive 'private-state-canonicalization\workspace'
    $shared = Join-Path $TestDrive 'private-state-canonicalization\shared'
    $taskId = 'task-projection-path-rebind-canonicalization'
    $canonicalContext = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $legacyCurrentContext = Join-Path (Split-Path -Parent $canonicalContext) ($taskId + '.json')
    Write-TestJson $legacyCurrentContext ([pscustomobject]@{taskId=$taskId;status='active';acceptedGoal='canonicalize without deleting legacy filename'})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $legacyCurrentContext $workspace $shared 0).exitCode | Should Be 0
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.entities.context.path = Join-Path (Join-Path $legacyRoot 'workspace') $legacyCurrentContext.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    Write-TestJson $projectionPath $projection
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $events = @(Get-Content -LiteralPath $eventPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($event in $events) { if ($event.entityKind -eq 'context' -and $event.entity) { $event.entity.path = [string]$projection.entities.context.path } }
    [IO.File]::WriteAllLines($eventPath,@($events | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }),[Text.UTF8Encoding]::new($false))

    $preview = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','canonicalize verified current legacy filename','-Json')
    $preview.exitCode | Should Be 0
    $preview.value.readyCount | Should Be 1
    $preview.value.candidates[0].materializationRequired | Should Be $true
    $preview.value.candidates[0].targetPath | Should Be $canonicalContext
    Test-Path -LiteralPath $canonicalContext | Should Be $false

    $applied = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','canonicalize verified current legacy filename','-ExpectedPlanFingerprint',[string]$preview.value.planFingerprint,'-Apply','-Json')
    if ($applied.exitCode -ne 0) { throw "REBIND_CANONICALIZATION_FAILED $($applied.text)" }
    $applied.value.reboundCount | Should Be 1
    $applied.value.appliedRecords[0].materializedCount | Should Be 1
    Test-Path -LiteralPath $legacyCurrentContext | Should Be $true
    Test-Path -LiteralPath $canonicalContext | Should Be $true
    (Get-FileHash -LiteralPath $legacyCurrentContext -Algorithm SHA256).Hash | Should Be (Get-FileHash -LiteralPath $canonicalContext -Algorithm SHA256).Hash
    (Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json).entities.context.path | Should Be $canonicalContext
  }

  It 'recovers an interrupted projection-path rebind as one task transaction' {
    $legacyRoot = Join-Path $TestDrive 'retired-state-root-recovery'
    $workspace = Join-Path $TestDrive 'private-state-recovery\workspace'
    $shared = Join-Path $TestDrive 'private-state-recovery\shared'
    $taskId = 'task-projection-path-rebind-recovery'
    $context = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpoint = Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint' 'active'
    $taskCard = Get-TestTaskStateTarget $workspace $shared $taskId 'task_card' 'active'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='active';pendingSteps=@('recover transaction')})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='active';pendingSteps=@('recover transaction')})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode | Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 1).exitCode | Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'task_card' $taskCard $workspace $shared 2).exitCode | Should Be 0
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.entities.context.path = Join-Path (Join-Path $legacyRoot 'workspace') $context.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $projection.entities.checkpoint.path = Join-Path (Join-Path $legacyRoot 'workspace') $checkpoint.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $projection.entities.task_card.path = Join-Path (Join-Path $legacyRoot 'shared') $taskCard.Substring($shared.Length).TrimStart([char[]]@('\','/'))
    Write-TestJson $projectionPath $projection
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $legacyPaths = @{ context=[string]$projection.entities.context.path; checkpoint=[string]$projection.entities.checkpoint.path; task_card=[string]$projection.entities.task_card.path }
    $events = @(Get-Content -LiteralPath $eventPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($event in $events) { if ($event.entityKind -and $event.entity -and $legacyPaths.ContainsKey([string]$event.entityKind)) { $event.entity.path = $legacyPaths[[string]$event.entityKind] } }
    [IO.File]::WriteAllLines($eventPath,@($events | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }),[Text.UTF8Encoding]::new($false))
    $preview = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','recoverable root migration regression','-Json')
    $preview.exitCode | Should Be 0

    $interrupted = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','recoverable root migration regression','-ExpectedPlanFingerprint',[string]$preview.value.planFingerprint,'-FaultPoint','after_prepare','-Apply','-Json')
    $interrupted.exitCode | Should Be 1
    (Invoke-TaskStateStore @('-Action','Audit','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Json')).value.incompleteTransactionCount | Should Be 1
    $beforeRecovery = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $beforeRecovery.entities.context.path | Should Match 'retired-state-root-recovery'
    $beforeRecovery.entities.checkpoint.path | Should Match 'retired-state-root-recovery'
    $beforeRecovery.entities.task_card.path | Should Match 'retired-state-root-recovery'

    $recovered = Invoke-TaskStateStore @('-Action','Reconcile','-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Apply','-Json')
    if ($recovered.exitCode -ne 0) { throw "REBIND_RECOVERY_FAILED $($recovered.text)" }
    $recovered.value.recoveredCount | Should Be 1
    $afterRecovery = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $afterRecovery.lifecycle.status | Should Be 'active'
    $afterRecovery.entities.context.path | Should Be $context
    $afterRecovery.entities.checkpoint.path | Should Be $checkpoint
    $afterRecovery.entities.task_card.path | Should Be $taskCard
  }

  It 'defers a completion-evidence conflict instead of rebinding it with normal active tasks' {
    $legacyRoot = Join-Path $TestDrive 'retired-state-root-conflict'
    $workspace = Join-Path $TestDrive 'private-state-conflict\workspace'
    $shared = Join-Path $TestDrive 'private-state-conflict\shared'
    $taskId = 'task-projection-path-rebind-conflict'
    $context = Get-TestTaskStateTarget $workspace $shared $taskId 'context'
    $checkpoint = Get-TestTaskStateTarget $workspace $shared $taskId 'checkpoint' 'completed'
    $taskCard = Get-TestTaskStateTarget $workspace $shared $taskId 'task_card' 'completed'
    Write-TestJson $context ([pscustomobject]@{taskId=$taskId;status='active'})
    Write-TestJson $checkpoint ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    Write-TestJson $taskCard ([pscustomobject]@{taskId=$taskId;status='completed';pendingSteps=@()})
    (Invoke-MaintenanceTaskStateRecord $taskId 'context' $context $workspace $shared 0).exitCode | Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'checkpoint' $checkpoint $workspace $shared 1).exitCode | Should Be 0
    (Invoke-MaintenanceTaskStateRecord $taskId 'task_card' $taskCard $workspace $shared 2).exitCode | Should Be 0
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.entities.context.path = Join-Path (Join-Path $legacyRoot 'workspace') $context.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $projection.entities.checkpoint.path = Join-Path (Join-Path $legacyRoot 'workspace') $checkpoint.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $projection.entities.task_card.path = Join-Path (Join-Path $legacyRoot 'shared') $taskCard.Substring($shared.Length).TrimStart([char[]]@('\','/'))
    Write-TestJson $projectionPath $projection
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $legacyPaths = @{ context=[string]$projection.entities.context.path; checkpoint=[string]$projection.entities.checkpoint.path; task_card=[string]$projection.entities.task_card.path }
    $events = @(Get-Content -LiteralPath $eventPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($event in $events) { if ($event.entityKind -and $event.entity -and $legacyPaths.ContainsKey([string]$event.entityKind)) { $event.entity.path = $legacyPaths[[string]$event.entityKind] } }
    [IO.File]::WriteAllLines($eventPath,@($events | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }),[Text.UTF8Encoding]::new($false))
    $beforeEventCount = @(Get-Content -LiteralPath $eventPath -Encoding UTF8).Count

    $preview = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','defer completion evidence conflict','-Json')
    $preview.exitCode | Should Be 0
    $preview.value.readyCount | Should Be 0
    $preview.value.deferredCount | Should Be 3
    $preview.value.invalidCount | Should Be 0
    @($preview.value.deferred | ForEach-Object { $_.reason } | Select-Object -Unique) | Should Be @('completion_evidence_conflict')

    $apply = Invoke-TaskStateStore @('-Action','RebindProjectionPaths','-LegacyStateRoot',$legacyRoot,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-MaintenanceOverride','-MaintenanceReason','defer completion evidence conflict','-ExpectedPlanFingerprint',[string]$preview.value.planFingerprint,'-Apply','-Json')
    $apply.exitCode | Should Be 0
    $apply.value.applied | Should Be $false
    $apply.value.deferredCount | Should Be 3
    @(Get-Content -LiteralPath $eventPath -Encoding UTF8).Count | Should Be $beforeEventCount
    (Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json).entities.context.path | Should Match 'retired-state-root-conflict'
  }
}
