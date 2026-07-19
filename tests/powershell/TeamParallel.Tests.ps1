$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$newScript = Join-Path $root 'scripts\team-task-new.ps1'
$addDelegationScript = Join-Path $root 'scripts\team-task-add-delegation.ps1'
$decisionScript = Join-Path $root 'scripts\team-task-decision.ps1'

function Invoke-TeamTaskJson([string]$Script,[string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = $null
  $start = $text.IndexOf('{')
  $end = $text.LastIndexOf('}')
  if ($start -ge 0 -and $end -ge $start) {
    try { $value = $text.Substring($start,$end-$start+1) | ConvertFrom-Json } catch {}
  }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

function New-TestTeamTask([string]$StateRoot,[string[]]$ExpectedJoinSlots) {
  $arguments = @(
    '-Goal','team parallel regression',
    '-DispatchLevel','team_parallel',
    '-ExpectedJoinSlots',($ExpectedJoinSlots -join ','),
    '-StateRoot',$StateRoot,
    '-Json'
  )
  $result = Invoke-TeamTaskJson $newScript $arguments
  $result.exitCode | Should Be 0
  $result.value.ok | Should Be $true
  return $result.value
}

Describe 'Team parallel join safety' {
  It 'requires declared join slots before creating a parallel task' {
    $stateRoot = Join-Path $TestDrive 'missing-slots-state'
    $missing = Invoke-TeamTaskJson $newScript @(
      '-Goal','parallel task without a join manifest',
      '-DispatchLevel','team_parallel',
      '-StateRoot',$stateRoot,
      '-Json'
    )

    $missing.exitCode | Should Be 1
    $missing.text | Should Match 'TEAM_TASK_JOIN_SLOTS_REQUIRED'
  }

  It 'preserves concurrent reports with collision-resistant task and delegation IDs' {
    $stateRoot = Join-Path $TestDrive 'concurrent-state'
    $workerCount = 8
    $slots = @(1..$workerCount | ForEach-Object { "slot-$_" })
    $created = New-TestTeamTask $stateRoot $slots
    $created.teamTaskId | Should Match '^team-\d{8}-\d{9}-[a-f0-9]{32}$'

    $jobs = @()
    try {
      foreach ($worker in 1..$workerCount) {
        $jobs += Start-Job -ArgumentList $addDelegationScript,$created.teamTaskId,$stateRoot,$worker -ScriptBlock {
          param($AddDelegationScript,$TeamTaskId,$StateRoot,$Worker)
          $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AddDelegationScript -TeamTaskId $TeamTaskId -Role "worker-$Worker" -Task "report-$Worker" -JoinSlotId "slot-$Worker" -IdempotencyKey "concurrent-$Worker" -StateRoot $StateRoot -Json 2>&1)
          [pscustomobject]@{ worker=$Worker; exitCode=$LASTEXITCODE; output=($raw -join "`n") }
        }
      }
      $workers = @($jobs | Wait-Job | Receive-Job)
    } finally {
      if ($jobs.Count -gt 0) { $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }
    }

    @($workers | Where-Object { $_.exitCode -ne 0 }).Count | Should Be 0
    $path = Join-Path $stateRoot "workspace\team-tasks\$($created.teamTaskId).json"
    $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    @($record.delegations).Count | Should Be $workerCount
    @($record.delegations.delegationId | Select-Object -Unique).Count | Should Be $workerCount
    @($record.delegations | Where-Object { $_.delegationId -notmatch '^delegation-\d{8}-\d{9}-[a-f0-9]{32}$' }).Count | Should Be 0
    @($record.expectedJoinSlots | Where-Object { $_.status -eq 'reported' }).Count | Should Be $workerCount
  }

  It 'treats a duplicate report retry as idempotent' {
    $stateRoot = Join-Path $TestDrive 'retry-state'
    $created = New-TestTeamTask $stateRoot @('slot-a')
    $arguments = @(
      '-TeamTaskId',$created.teamTaskId,
      '-Role','worker-a',
      '-Task','retry report',
      '-JoinSlotId','slot-a',
      '-IdempotencyKey','retry-1',
      '-Findings','same finding',
      '-Evidence','same evidence',
      '-StateRoot',$stateRoot,
      '-Json'
    )

    $first = Invoke-TeamTaskJson $addDelegationScript $arguments
    $second = Invoke-TeamTaskJson $addDelegationScript $arguments

    $first.exitCode | Should Be 0
    $second.exitCode | Should Be 0
    $first.value.delegationId | Should Match '^delegation-\d{8}-\d{9}-[a-f0-9]{32}$'
    $second.value.idempotent | Should Be $true
    $second.value.delegationId | Should Be $first.value.delegationId
    $path = Join-Path $stateRoot "workspace\team-tasks\$($created.teamTaskId).json"
    @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).delegations).Count | Should Be 1
  }

  It 'blocks rejection and acceptance until every expected slot is terminal and integrated' {
    $stateRoot = Join-Path $TestDrive 'join-gate-state'
    $created = New-TestTeamTask $stateRoot @('slot-a','slot-b')
    $firstReport = Invoke-TeamTaskJson $addDelegationScript @(
      '-TeamTaskId',$created.teamTaskId,
      '-Role','worker-a',
      '-Task','first report',
      '-JoinSlotId','slot-a',
      '-IdempotencyKey','first-report',
      '-StateRoot',$stateRoot,
      '-Json'
    )
    $firstReport.exitCode | Should Be 0

    $rejected = Invoke-TeamTaskJson $decisionScript @(
      '-TeamTaskId',$created.teamTaskId,
      '-Status','rejected',
      '-IntegratedJoinSlots','slot-a',
      '-StateRoot',$stateRoot,
      '-Json'
    )
    $rejected.exitCode | Should Be 1
    $rejected.text | Should Match 'TEAM_TASK_JOIN_INCOMPLETE.*expected_join_slot_pending:slot-b'

    $secondReport = Invoke-TeamTaskJson $addDelegationScript @(
      '-TeamTaskId',$created.teamTaskId,
      '-Role','worker-b',
      '-Task','second report',
      '-JoinSlotId','slot-b',
      '-IdempotencyKey','second-report',
      '-StateRoot',$stateRoot,
      '-Json'
    )
    $secondReport.exitCode | Should Be 0

    $unintegrated = Invoke-TeamTaskJson $decisionScript @(
      '-TeamTaskId',$created.teamTaskId,
      '-Status','accepted',
      '-IntegratedJoinSlots','slot-a',
      '-StateRoot',$stateRoot,
      '-Json'
    )
    $unintegrated.exitCode | Should Be 1
    $unintegrated.text | Should Match 'TEAM_TASK_JOIN_INCOMPLETE.*expected_join_slot_not_integrated:slot-b'

    $accepted = Invoke-TeamTaskJson $decisionScript @(
      '-TeamTaskId',$created.teamTaskId,
      '-Status','accepted',
      '-IntegratedJoinSlots','slot-a,slot-b',
      '-StateRoot',$stateRoot,
      '-Json'
    )
    $accepted.exitCode | Should Be 0
    $accepted.value.decision.status | Should Be 'accepted'
    $accepted.value.decision.join.status | Should Be 'complete'
    $accepted.value.decision.join.integratedSlotCount | Should Be 2
  }
}
