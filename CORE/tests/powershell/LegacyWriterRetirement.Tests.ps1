$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$StepLedger = Join-Path $Root 'scripts\step-ledger.ps1'
$SessionCompact = Join-Path $Root 'scripts\session-compact.ps1'
$ProjectContinuity = Join-Path $Root 'scripts\project-continuity.ps1'
$TaskIndex = Join-Path $Root 'scripts\task-index.ps1'
$StatusSnapshotWriter = Join-Path $Root 'scripts\status-snapshot-writer.ps1'
$ChangeIntegrity = Join-Path $Root 'scripts\change-integrity.ps1'
. (Join-Path $Root 'scripts\common.ps1')

function Write-LegacyWriterTestJson([string]$Path,[object]$Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Invoke-LegacyWriterTestScript([string]$ScriptPath,[string[]]$Arguments,[string]$StateRoot) {
  $previousState = $env:SUPER_BRAIN_STATE_ROOT
  $previousArchive = $env:SUPER_BRAIN_ARCHIVE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $env:SUPER_BRAIN_ARCHIVE_ROOT = Join-Path $StateRoot 'archive'
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previousState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousState }
    if ($null -eq $previousArchive) { Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $previousArchive }
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$exitCode; text=$text; value=if($text){$text|ConvertFrom-Json}else{$null} }
}

Describe 'P5 retired global writer boundaries' {
  It 'requires task and workspace scope before step-ledger mutations' {
    $stateRoot = Join-Path $TestDrive 'step-scope-required'
    $result = Invoke-LegacyWriterTestScript $StepLedger @('-Action','Upsert','-Step','must not write globally','-Json') $stateRoot
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'STEP_LEDGER_TASK_SCOPE_REQUIRED'
    Test-Path -LiteralPath (Join-Path $stateRoot 'workspace\step-ledger.json') | Should Be $false
  }

  It 'keeps same task identifiers isolated across workspaces without rewriting the legacy projection' {
    $stateRoot = Join-Path $TestDrive 'step-workspace-isolation'
    $taskId = 'task-shared-ledger'
    $workspaceA = 'G:\legacy-writer-tests\workspace-a'
    $workspaceB = 'G:\legacy-writer-tests\workspace-b'
    $keyA = Get-SuperBrainWorkspaceKey $workspaceA
    $keyB = Get-SuperBrainWorkspaceKey $workspaceB

    $first = Invoke-LegacyWriterTestScript $StepLedger @('-Action','Upsert','-TaskId',$taskId,'-WorkspaceKey',$workspaceA,'-StepId','a','-Step','workspace A step','-Json') $stateRoot
    $first.exitCode | Should Be 0
    $second = Invoke-LegacyWriterTestScript $StepLedger @('-Action','Upsert','-TaskId',$taskId,'-WorkspaceKey',$workspaceB,'-StepId','b','-Step','workspace B step','-Json') $stateRoot
    $second.exitCode | Should Be 0
    $first.value.ledgerPath | Should Not Be $second.value.ledgerPath

    $ledgerA = Get-Content -LiteralPath $first.value.ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ledgerB = Get-Content -LiteralPath $second.value.ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ledgerA.workspaceKey | Should Be $keyA
    $ledgerB.workspaceKey | Should Be $keyB
    $ledgerA.openSteps[0].step | Should Be 'workspace A step'
    $ledgerB.openSteps[0].step | Should Be 'workspace B step'
    Test-Path -LiteralPath (Join-Path $stateRoot 'workspace\step-ledger.json') | Should Be $false
    Test-Path -LiteralPath (Join-Path $stateRoot 'workspace\last-step-ledger.json') | Should Be $false
  }

  It 'reads a compatible legacy ledger only when its exact task and workspace match' {
    $stateRoot = Join-Path $TestDrive 'step-legacy-read'
    $workspace = Join-Path $stateRoot 'project'
    $key = Get-SuperBrainWorkspaceKey $workspace
    $legacyPath = Join-Path $stateRoot 'workspace\step-ledger.json'
    Write-LegacyWriterTestJson $legacyPath ([pscustomobject]@{ taskId='task-legacy-read'; workspaceKey=$key; openSteps=@([pscustomobject]@{step='legacy scoped step'}); completedSteps=@(); blockedSteps=@(); skippedSteps=@() })
    $selection = Get-SuperBrainRelevantStepLedger (Join-Path $stateRoot 'workspace') 'task-legacy-read' $workspace -AllowLegacyRead
    $selection.source | Should Be 'legacy_global_read_only'
    $selection.ledger.openSteps[0].step | Should Be 'legacy scoped step'

    $foreign = Get-SuperBrainRelevantStepLedger (Join-Path $stateRoot 'workspace') 'task-legacy-read' (Join-Path $stateRoot 'other-project') -AllowLegacyRead
    $foreign.ledger | Should BeNullOrEmpty
  }

  It 'archives compact notes per task/workspace and never recreates session-notes.md' {
    $stateRoot = Join-Path $TestDrive 'compact-archive'
    $taskId = 'task-compact'
    $workspace = 'G:\legacy-writer-tests\compact'
    $result = Invoke-LegacyWriterTestScript $SessionCompact @('-InputText',"verified: scope isolation complete`nNext: run focused regression",'-Title','P5 note','-TaskId',$taskId,'-WorkspaceKey',$workspace,'-SessionId','session-compact-test','-Json') $stateRoot
    $result.exitCode | Should Be 0
    $result.value.historicalOnly | Should Be $true
    $result.value.nonAuthorizing | Should Be $true
    Test-Path -LiteralPath $result.value.path | Should Be $true
    Test-Path -LiteralPath (Join-Path $stateRoot 'workspace\session-notes.md') | Should Be $false
    $record = Get-Content -LiteralPath $result.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $record.taskId | Should Be $taskId
    $record.workspaceKey | Should Be (Get-SuperBrainWorkspaceKey $workspace)
    $record.nonAuthorizing | Should Be $true

    $unscoped = Invoke-LegacyWriterTestScript $SessionCompact @('-InputText','do not write globally','-Json') $stateRoot
    $unscoped.exitCode | Should Be 1
    $unscoped.value.code | Should Be 'SESSION_COMPACT_TASK_SCOPE_REQUIRED'
  }

  It 'retires project-continuity mutations without recreating global task projections' {
    $stateRoot = Join-Path $TestDrive 'project-continuity-retired'
    $workspace = 'G:\legacy-writer-tests\project-continuity'
    $status = Invoke-LegacyWriterTestScript $ProjectContinuity @('-Action','Status','-WorkspaceKey',$workspace,'-Json') $stateRoot
    $status.exitCode | Should Be 0
    $status.value.status | Should Be 'retired_read_only'
    $status.value.code | Should Be 'PROJECT_CONTINUITY_LEGACY_WRITER_RETIRED'

    $mutation = Invoke-LegacyWriterTestScript $ProjectContinuity @('-Action','StartTask','-TaskId','task-legacy-project','-WorkspaceKey',$workspace,'-Goal','must not create a second state authority','-Json') $stateRoot
    $mutation.exitCode | Should Be 1
    $mutation.value.status | Should Be 'retired_error'
    $mutation.value.code | Should Be 'PROJECT_CONTINUITY_LEGACY_WRITER_RETIRED'
    foreach ($name in @('project-graph.json','task-graph.json','structure-baseline.json','step-ledger.json','last-project-continuity.json')) {
      Test-Path -LiteralPath (Join-Path $stateRoot ('workspace\' + $name)) | Should Be $false
    }
  }

  It 'keeps a legacy task graph out of normal task selection and exposes it only as a diagnostic' {
    $stateRoot = Join-Path $TestDrive 'task-index-legacy-read-only'
    $workspace = 'G:\legacy-writer-tests\task-index'
    $workspaceKey = Get-SuperBrainWorkspaceKey $workspace
    Write-LegacyWriterTestJson (Join-Path $stateRoot 'workspace\task-graph.json') ([pscustomobject]@{
      taskId='task-legacy-index'; workspaceKey=$workspaceKey; goal='legacy graph must not resume automatically'; status='active'; updatedAt=(Get-Date).ToString('o')
    })

    $normal = Invoke-LegacyWriterTestScript $TaskIndex @('-WorkspaceKey',$workspace,'-Json') $stateRoot
    $normal.exitCode | Should Be 0
    @($normal.value.current | Where-Object { $_.taskId -eq 'task-legacy-index' }).Count | Should Be 0
    @($normal.value.all | Where-Object { $_.taskId -eq 'task-legacy-index' }).Count | Should Be 0

    $diagnostic = Invoke-LegacyWriterTestScript $TaskIndex @('-WorkspaceKey',$workspace,'-IncludeDiagnostic','-Json') $stateRoot
    $diagnostic.exitCode | Should Be 0
    $candidate = @($diagnostic.value.candidates | Where-Object { $_.taskId -eq 'task-legacy-index' }) | Select-Object -First 1
    $candidate.status | Should Be 'legacy_read_only'
    $candidate.source | Should Match 'migration diagnostic'
  }

  It 'does not let a legacy task graph establish the current status snapshot' {
    $stateRoot = Join-Path $TestDrive 'status-snapshot-legacy-read-only'
    $workspace = 'G:\legacy-writer-tests\status-snapshot'
    $workspaceKey = Get-SuperBrainWorkspaceKey $workspace
    $legacyPath = Join-Path $stateRoot 'workspace\task-graph.json'
    Write-LegacyWriterTestJson $legacyPath ([pscustomobject]@{
      taskId='task-legacy-status'; workspaceKey=$workspaceKey; goal='legacy graph must remain diagnostic'; status='active'; updatedAt=(Get-Date).ToString('o')
    })
    $beforeHash = (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash

    $snapshot = Invoke-LegacyWriterTestScript $StatusSnapshotWriter @('-WorkspaceKey',$workspace,'-Json') $stateRoot
    $snapshot.exitCode | Should Be 0
    $snapshot.value.continuity.taskId | Should BeNullOrEmpty
    $snapshot.value.continuity.source | Should Be 'none'
    $snapshot.value.continuity.legacyCompatibility.taskGraphObserved | Should Be $true
    $snapshot.value.continuity.legacyCompatibility.taskGraphApplied | Should Be $false
    (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash | Should Be $beforeHash
  }

  It 'checks compact routing against canonical cold governance instead of restoring bloated hot rules' {
    $stateRoot = Join-Path $TestDrive 'change-integrity-cold-governance'
    $integrity = Invoke-LegacyWriterTestScript $ChangeIntegrity @('-Json') $stateRoot
    $integrity.exitCode | Should Be 0
    $integrity.value.ok | Should Be $true
    @($integrity.value.results | Where-Object { $_.id -eq 'short-router-cold-pointers' -and $_.ok -eq $true }).Count | Should Be 1
    @($integrity.value.results | Where-Object { $_.id -eq 'continuity-and-session-isolation' -and $_.ok -eq $true }).Count | Should Be 1
  }
}
