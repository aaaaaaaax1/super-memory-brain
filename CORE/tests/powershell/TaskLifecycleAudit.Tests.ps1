$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$checkpointScript = Join-Path $root 'scripts\checkpoint-writer.ps1'
$auditScript = Join-Path $root 'scripts\task-lifecycle-audit.ps1'
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$contextScript = Join-Path $root 'scripts\current-task-context.ps1'

. (Join-Path $root 'scripts\common.ps1')

function Write-LifecycleTestJson([string]$Path,[object]$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Invoke-LifecycleScript([string]$ScriptPath,[string[]]$Arguments,[string]$StateRoot) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  $previousErrorActionPreference = $ErrorActionPreference
  $nativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($nativeErrorPreference) { $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference.Value }
    else { Remove-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue }
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n")
  return [pscustomobject]@{ exitCode=$exitCode; value=if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}; text=$text }
}

Describe 'Task lifecycle checkpoint authority' {
  It 'treats an exact bound active contract as authority before checkpoint registration' {
    $stateRoot = Join-Path $TestDrive 'contract-backed-context'
    $taskId = 'task-contract-backed-context'
    $workspaceKey = 'ws-a00000000000000000000000'
    $sessionKey = 'sid-contract-backed-context'
    (Invoke-LifecycleScript $contractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','register checkpoint later','-StateRoot',$stateRoot,'-Json') $stateRoot).exitCode | Should Be 0
    (Invoke-LifecycleScript $contextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-contract-backed','-SessionId','context-contract-backed','-Platform','zcode','-OwnerWorkspace','G:\contract-backed-context','-AcceptedGoal','keep contract authority exact','-AcceptedRoute','contract before checkpoint','-Json') $stateRoot).exitCode | Should Be 0

    $audit = Invoke-LifecycleScript $auditScript @('-Json') $stateRoot
    $audit.exitCode | Should Be 0
    $audit.value.ok | Should Be $true
    $audit.value.counts.orphanActiveContexts | Should Be 0
    $audit.value.counts.hardFindings | Should Be 0
    $audit.value.counts.activeProjectionEntityParityFailures | Should Be 0
  }

  It 'does not classify a stale zero-pending task card as completion when its checkpoint has pending work' {
    $stateRoot = Join-Path $TestDrive 'card-checkpoint-divergence'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $taskId = 'task-authoritative-checkpoint'
    $workspaceKey = 'ws-a11111111111111111111111'

    (Invoke-LifecycleScript $checkpointScript @('-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TaskName','Authoritative checkpoint','-CurrentStep','keep working','-PendingSteps','authoritative pending step','-Json') $stateRoot).exitCode | Should Be 0
    $cardPath = Get-SuperBrainCanonicalTaskPath (Join-Path $shared 'tasks\active') $taskId '.task.json'
    $card = Get-Content -LiteralPath $cardPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $card.pendingSteps = @()
    Write-LifecycleTestJson $cardPath $card

    $before = Invoke-LifecycleScript $auditScript @('-Json') $stateRoot
    $before.exitCode | Should Be 1
    $before.value.counts.zeroPendingActiveCards | Should Be 0
    $before.value.counts.cardCheckpointDivergences | Should Be 1
    $before.value.counts.activeProjectionEntityParityFailures | Should Be 1
    $before.value.cardCheckpointDivergences[0].taskId | Should Be $taskId
    $before.value.cardCheckpointDivergences[0].checkpointPendingCount | Should Be 1

    $refresh = Invoke-LifecycleScript $checkpointScript @('-Action','RefreshTaskCard','-TaskId',$taskId,'-Json') $stateRoot
    $refresh.exitCode | Should Be 0
    $refresh.value.pendingStepCount | Should Be 1
    $after = Invoke-LifecycleScript $auditScript @('-Json') $stateRoot
    $after.exitCode | Should Be 0
    $after.value.counts.zeroPendingActiveCards | Should Be 0
    $after.value.counts.cardCheckpointDivergences | Should Be 0
    @((Get-Content -LiteralPath $cardPath -Raw -Encoding UTF8 | ConvertFrom-Json).pendingSteps).Count | Should Be 1
  }

  It 'never promotes a compatibility checkpoint from another workspace after completion' {
    $stateRoot = Join-Path $TestDrive 'workspace-filtered-pointer'
    $workspace = Join-Path $stateRoot 'workspace'
    $alpha = 'ws-a22222222222222222222222'
    $beta = 'ws-b33333333333333333333333'

    (Invoke-LifecycleScript $checkpointScript @('-Action','Start','-TaskId','task-alpha','-WorkspaceKey',$alpha,'-TaskName','Alpha','-CurrentStep','alpha','-Json') $stateRoot).exitCode | Should Be 0
    (Invoke-LifecycleScript $checkpointScript @('-Action','Start','-TaskId','task-beta','-WorkspaceKey',$beta,'-TaskName','Beta','-CurrentStep','beta','-Json') $stateRoot).exitCode | Should Be 0
    $completed = Invoke-LifecycleScript $checkpointScript @('-Action','Complete','-TaskId','task-alpha','-WorkspaceKey',$alpha,'-MaintenanceOverride','-MaintenanceReason','isolated lifecycle regression cleanup','-Json') $stateRoot
    $completed.exitCode | Should Be 0

    Test-Path -LiteralPath (Join-Path $workspace 'active-checkpoint.json') | Should Be $false
    (Invoke-LifecycleScript $checkpointScript @('-Action','Get','-TaskId','task-beta','-Json') $stateRoot).value.status | Should Be 'active'
    $receiptPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\task-completion-receipts') 'task-alpha' '.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    [string]$receipt.taskInstanceId | Should Match '^ti-[a-f0-9]{32}$'
    [string]$receipt.workspaceKey | Should Be $alpha
  }

  It 'requires an explicit maintenance reason before overriding a stale task-card owner' {
    $stateRoot = Join-Path $TestDrive 'owner-guarded-refresh'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $taskId = 'task-owner-guarded-refresh'
    $workspaceKey = 'ws-a44444444444444444444444'
    (Invoke-LifecycleScript $checkpointScript @('-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TaskName','Owner guarded','-CurrentStep','keep working','-PendingSteps','pending','-Json') $stateRoot).exitCode | Should Be 0

    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.entities.task_card.owner.sessionId = 'foreign-session'
    Write-LifecycleTestJson $projectionPath $projection

    $blocked = Invoke-LifecycleScript $checkpointScript @('-Action','RefreshTaskCard','-TaskId',$taskId,'-Json') $stateRoot
    $blocked.exitCode | Should Be 1
    $missingReason = Invoke-LifecycleScript $checkpointScript @('-Action','RefreshTaskCard','-TaskId',$taskId,'-MaintenanceOverride','-Json') $stateRoot
    $missingReason.exitCode | Should Be 1

    $repaired = Invoke-LifecycleScript $checkpointScript @('-Action','RefreshTaskCard','-TaskId',$taskId,'-MaintenanceOverride','-MaintenanceReason','repair stale card from authoritative checkpoint','-Json') $stateRoot
    $repaired.exitCode | Should Be 0
    $repaired.value.maintenanceOverride | Should Be $true
    $repaired.value.maintenanceReason | Should Match 'authoritative checkpoint'
  }

  It 'requires a reason before a recovered session reactivates a blocked checkpoint owner' {
    $stateRoot = Join-Path $TestDrive 'owner-guarded-start'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $taskId = 'task-owner-guarded-start'
    $workspaceKey = 'ws-a55555555555555555555555'

    (Invoke-LifecycleScript $checkpointScript @('-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TaskName','Blocked checkpoint','-SessionId','old-session','-AgentId','old-agent','-Status','blocked','-CurrentStep','await recovery','-Json') $stateRoot).exitCode | Should Be 0

    $blocked = Invoke-LifecycleScript $checkpointScript @('-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TaskName','Recovered checkpoint','-SessionId','new-session','-AgentId','new-agent','-Status','active','-CurrentStep','resume authorized work','-Json') $stateRoot
    $blocked.exitCode | Should Be 1

    $missingReason = Invoke-LifecycleScript $checkpointScript @('-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TaskName','Recovered checkpoint','-SessionId','new-session','-AgentId','new-agent','-Status','active','-CurrentStep','resume authorized work','-MaintenanceOverride','-Json') $stateRoot
    $missingReason.exitCode | Should Be 1

    $recovered = Invoke-LifecycleScript $checkpointScript @('-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TaskName','Recovered checkpoint','-SessionId','new-session','-AgentId','new-agent','-Status','active','-CurrentStep','resume authorized work','-MaintenanceOverride','-MaintenanceReason','explicit user-authorized continuity recovery','-Json') $stateRoot
    $recovered.exitCode | Should Be 0
    $recovered.value.status | Should Be 'active'

    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.lifecycle.status | Should Be 'active'
    $projection.entities.checkpoint.owner.sessionId | Should Be 'new-session'
    $projection.entities.task_card.owner.sessionId | Should Be 'new-session'
    Test-Path -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $shared 'tasks\active') $taskId '.task.json') | Should Be $true
    Test-Path -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $shared 'tasks\blocked') $taskId '.task.json') | Should Be $false
  }

  It 'fails closed when terminal evidence conflicts with an active task context' {
    $stateRoot = Join-Path $TestDrive 'completion-evidence-conflict'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $taskId = 'task-completion-evidence-conflict'
    $workspaceKey = 'ws-a66666666666666666666666'
    $contextPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\current-task-contexts') $taskId '.json'
    $checkpointPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\checkpoints\completed') $taskId '.json'
    $taskCardPath = Get-SuperBrainCanonicalTaskPath (Join-Path $shared 'tasks\completed') $taskId '.task.json'
    Write-LifecycleTestJson $contextPath ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; status='active' })
    Write-LifecycleTestJson $checkpointPath ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; status='completed' })
    Write-LifecycleTestJson $taskCardPath ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; status='completed' })
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    Write-LifecycleTestJson $projectionPath ([pscustomobject]@{
      schema='super-brain.task-state-projection.v2';taskId=$taskId;revision=3;updatedAt=(Get-Date).ToString('o');lastEventId='conflict-event'
      entities=[pscustomobject]@{
        context=[pscustomobject]@{ path=$contextPath; hash=(Get-FileHash -LiteralPath $contextPath -Algorithm SHA256).Hash; status='active' }
        checkpoint=[pscustomobject]@{ path=$checkpointPath; hash=(Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash; status='completed' }
        task_card=[pscustomobject]@{ path=$taskCardPath; hash=(Get-FileHash -LiteralPath $taskCardPath -Algorithm SHA256).Hash; status='completed' }
      }
      lifecycle=[pscustomobject]@{status='active';workspaceKey=$workspaceKey;ownerSessionKey='';planFingerprint='';contractRevision=0}
    })

    $audit = Invoke-LifecycleScript $auditScript @('-Json') $stateRoot

    $audit.exitCode | Should Be 1
    $audit.value.ok | Should Be $false
    $audit.value.reconciliationRequired | Should Be $true
    $audit.value.counts.completionEvidenceConflicts | Should Be 1
    $audit.value.counts.hardFindings | Should BeGreaterThan 0
  }

  It 'resolves migrated projection paths read-only only when canonical hashes match' {
    $stateRoot = Join-Path $TestDrive 'migrated-projection-paths'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $legacyRoot = Join-Path $TestDrive 'retired-state-root'
    $taskId = 'task-migrated-projection-paths'
    $workspaceKey = 'ws-a77777777777777777777777'
    $contextPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\current-task-contexts') $taskId '.json'
    $checkpointPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\checkpoints\active') $taskId '.json'
    $taskCardPath = Get-SuperBrainCanonicalTaskPath (Join-Path $shared 'tasks\active') $taskId '.task.json'
    Write-LifecycleTestJson $contextPath ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; status='active' })
    Write-LifecycleTestJson $checkpointPath ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; status='active'; pendingSteps=@('continue') })
    Write-LifecycleTestJson $taskCardPath ([pscustomobject]@{ taskId=$taskId; taskName='Migrated projection'; workspaceKey=$workspaceKey; status='active'; pendingSteps=@('continue'); updatedAt=(Get-Date).ToString('o') })
    $legacyContext = Join-Path (Join-Path $legacyRoot 'workspace') $contextPath.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $legacyCheckpoint = Join-Path (Join-Path $legacyRoot 'workspace') $checkpointPath.Substring($workspace.Length).TrimStart([char[]]@('\','/'))
    $legacyTaskCard = Join-Path (Join-Path $legacyRoot 'shared') $taskCardPath.Substring($shared.Length).TrimStart([char[]]@('\','/'))
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    Write-LifecycleTestJson $projectionPath ([pscustomobject]@{
      schema='super-brain.task-state-projection.v2';taskId=$taskId;revision=1;updatedAt=(Get-Date).ToString('o');lastEventId='migration-event'
      entities=[pscustomobject]@{
        context=[pscustomobject]@{ path=$legacyContext; hash=(Get-FileHash -LiteralPath $contextPath -Algorithm SHA256).Hash; status='active' }
        checkpoint=[pscustomobject]@{ path=$legacyCheckpoint; hash=(Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash; status='active' }
        task_card=[pscustomobject]@{ path=$legacyTaskCard; hash=(Get-FileHash -LiteralPath $taskCardPath -Algorithm SHA256).Hash; status='active' }
      }
      lifecycle=[pscustomobject]@{status='active';workspaceKey=$workspaceKey;ownerSessionKey='';planFingerprint='';contractRevision=0}
    })

    $audit = Invoke-LifecycleScript $auditScript @('-Json') $stateRoot
    $audit.exitCode | Should Be 0
    $audit.value.ok | Should Be $true
    $audit.value.counts.activeProjectionEntityParityFailures | Should Be 0
    $audit.value.counts.migratedProjectionPathsResolved | Should Be 3
    @($audit.value.migratedProjectionPathResolutions).Count | Should Be 3
    @($audit.value.migratedProjectionPathResolutions | Where-Object { $_.resolution -ne 'hash_verified_migration_alias' }).Count | Should Be 0
    Test-Path -LiteralPath $legacyRoot | Should Be $false
  }

  It 'reports a hash-verified quarantine disposition as resolved non-completion state' {
    $stateRoot = Join-Path $TestDrive 'quarantined-state'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-quarantined-audit'
    $manifestPath = Join-Path $workspace 'task-state-store\quarantine\ambiguous-state\task\txn\quarantine-manifest.json'
    Write-LifecycleTestJson $manifestPath ([pscustomobject]@{schema='super-brain.ambiguous-state-quarantine.v1';taskId=$taskId;completionInferred=$false})
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    Write-LifecycleTestJson $projectionPath ([pscustomobject]@{
      schema='super-brain.task-state-projection.v2';taskId=$taskId;revision=4;updatedAt='2026-07-21 00:00:00';lastEventId='quarantine-event'
      entities=[pscustomobject]@{context=$null;checkpoint=$null;task_card=$null}
      lifecycle=[pscustomobject]@{status='quarantined';workspaceKey='';ownerSessionKey='';planFingerprint='';contractRevision=0;completionTransactionId='';completedAt='';quarantineTransactionId='txn';quarantinedAt='2026-07-21 00:00:00';quarantineReason='completion_evidence_conflict';quarantineManifestPath=$manifestPath;quarantineManifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash;source='test'}
    })

    $audit = Invoke-LifecycleScript $auditScript @('-Json') $stateRoot
    $audit.exitCode | Should Be 0
    $audit.value.schema | Should Be 'super-brain.task-lifecycle-audit.v2'
    $audit.value.counts.quarantinedProjections | Should Be 1
    $audit.value.counts.completionEvidenceConflicts | Should Be 0
    $audit.value.quarantinedProjections[0].taskId | Should Be $taskId
    $audit.value.quarantinedProjections[0].manifestHashValid | Should Be $true
    $audit.value.reconciliationRequired | Should Be $false
  }
}
