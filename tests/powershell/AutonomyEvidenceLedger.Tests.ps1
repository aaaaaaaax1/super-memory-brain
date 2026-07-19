$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ledgerScript = Join-Path $root 'scripts\autonomy-evidence-ledger.ps1'
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$workspaceKey = 'ws-111111111111111111111111'

function Write-LedgerJson([string]$Path, $Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}

function Invoke-Ledger([string]$Workspace) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ledgerScript -Action Audit -WorkspaceRoot $Workspace -WorkspaceKey $workspaceKey -Json 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; text=$text; value=($text | ConvertFrom-Json) }
}

function Write-CompletedCheckpoint([string]$Workspace, [string]$TaskId) {
  Write-LedgerJson (Join-Path $Workspace "runtime-state\checkpoints\completed\$TaskId.json") ([pscustomobject]@{ schema='super-brain.checkpoint.v1'; taskId=$TaskId; status='completed'; source='task-verification.ps1' })
}

function Write-Authorization([string]$Workspace, [string]$TaskId) {
  $path = Join-Path $Workspace "runtime-state\autonomy-authorizations\$TaskId.json"
  Write-LedgerJson $path ([pscustomobject]@{
    schema='super-brain.governed-autonomy-authorization.v1'; recordId=('autonomy-auth-' + $TaskId); taskId=$TaskId; workspaceKey=$workspaceKey; packageVersion=[string]$manifest.version; authorizedAt=(Get-Date).ToString('o'); source='autonomous-executor.ps1'; authorizationMode='approved_plan'; autonomyTier='align'; executionHardGateOk=$true; checkpointCreated=$true; rawGoalStored=$false; rawPromptStored=$false
  })
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Outcome([string]$Workspace, [string]$TaskId, [string]$AuthorizationHash = '', [string]$CorrectionCandidateId = '') {
  $record = [pscustomobject]@{
    schema='super-brain.verified-task-outcome.v1'; recordId=('verified-task-' + $TaskId); taskId=$TaskId; workspaceKey=$workspaceKey; packageVersion=[string]$manifest.version; recordedAt=(Get-Date).ToString('o'); source='task-verification.ps1'
    verification=[pscustomobject]@{ ok=$true; taskScopedGuardOk=$true; realUserPathVerified=$true; completedCheckpointVerified=$true; packageVerificationOk=$true; hotRefreshOk=$true }
    classification=[pscustomobject]@{ verifiedRealWorldTask=$true; verifiedAutonomyScenario=(-not [string]::IsNullOrWhiteSpace($AuthorizationHash)) }
    authorization=if([string]::IsNullOrWhiteSpace($AuthorizationHash)){$null}else{[pscustomobject]@{recordId=('autonomy-auth-' + $TaskId);sha256=$AuthorizationHash;source='autonomous-executor.ps1';autonomyTier='align'}}
    correctionCandidateId=$CorrectionCandidateId
    evidenceRefs=@('task-verification.ps1','completed-checkpoint','last-verify-package.json','last-hot-refresh.json','integration-parity-check')
    privacy=[pscustomobject]@{rawPromptStored=$false;rawSummaryStored=$false}
  }
  $path = Join-Path $Workspace "runtime-state\verified-task-outcomes\$TaskId.json"
  Write-LedgerJson $path $record
  return [pscustomobject]@{ path=$path; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); record=$record }
}

Describe 'Autonomy evidence ledger' {
  It 'does not treat generic completed checkpoints or task cards as autonomy evidence' {
    $workspace = Join-Path $TestDrive 'generic-completion'
    Write-CompletedCheckpoint $workspace 'task-generic-completed'
    Write-LedgerJson (Join-Path $workspace 'shared-task-card.json') ([pscustomobject]@{ schema='super-brain.task-card.v1'; taskId='task-generic-completed'; status='completed' })

    $result = Invoke-Ledger $workspace
    $result.exitCode | Should Be 0
    $result.value.evidenceCounts.verifiedRealWorldTasks | Should Be 0
    $result.value.evidenceCounts.verifiedAutonomyScenarios | Should Be 0
    $result.value.evidenceCounts.closedCorrectionLoops | Should Be 0
    $result.value.provenance.completedCheckpointOrTaskCardAloneCounts | Should Be $false
  }

  It 'counts only a complete verified task, authorization, and correction chain' {
    $workspace = Join-Path $TestDrive 'complete-chain'
    $taskId = 'task-ledger-chain'
    $candidateId = 'correction-ledger-chain'
    Write-CompletedCheckpoint $workspace $taskId
    $authorizationHash = Write-Authorization $workspace $taskId
    $outcome = Write-Outcome $workspace $taskId $authorizationHash $candidateId
    Write-LedgerJson (Join-Path $workspace "reflection\correction-candidates\$candidateId.json") ([pscustomobject]@{
      schema='super-brain.correction-candidate.v1'; candidateId=$candidateId; workspaceKey=$workspaceKey; status='closed'; rawPromptStored=$false
      autonomyEvidenceLink=[pscustomobject]@{ eligible=$true; taskId=$taskId; verifiedOutcomeRecordId=$outcome.record.recordId; verifiedOutcomeSha256=$outcome.sha256; rawPromptStored=$false }
    })

    $result = Invoke-Ledger $workspace
    $result.exitCode | Should Be 0
    $result.value.evidenceCounts.verifiedRealWorldTasks | Should Be 1
    $result.value.evidenceCounts.verifiedAutonomyScenarios | Should Be 1
    $result.value.evidenceCounts.closedCorrectionLoops | Should Be 1
    $result.value.records.rejectedCount | Should Be 0
  }

  It 'rejects a correction link when the verified outcome hash changes' {
    $workspace = Join-Path $TestDrive 'hash-mismatch'
    $taskId = 'task-ledger-mismatch'
    $candidateId = 'correction-ledger-mismatch'
    Write-CompletedCheckpoint $workspace $taskId
    $authorizationHash = Write-Authorization $workspace $taskId
    $outcome = Write-Outcome $workspace $taskId $authorizationHash $candidateId
    Write-LedgerJson (Join-Path $workspace "reflection\correction-candidates\$candidateId.json") ([pscustomobject]@{
      schema='super-brain.correction-candidate.v1'; candidateId=$candidateId; workspaceKey=$workspaceKey; status='closed'; rawPromptStored=$false
      autonomyEvidenceLink=[pscustomobject]@{ eligible=$true; taskId=$taskId; verifiedOutcomeRecordId=$outcome.record.recordId; verifiedOutcomeSha256='00'; rawPromptStored=$false }
    })

    $result = Invoke-Ledger $workspace
    $result.exitCode | Should Be 0
    $result.value.evidenceCounts.verifiedRealWorldTasks | Should Be 1
    $result.value.evidenceCounts.closedCorrectionLoops | Should Be 0
    @($result.value.records.rejections | ForEach-Object { $_.reasons }) -contains 'linked_outcome_hash_mismatch' | Should Be $true
  }
}
