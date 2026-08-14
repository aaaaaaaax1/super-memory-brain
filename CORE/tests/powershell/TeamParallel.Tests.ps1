$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$newScript = Join-Path $root 'scripts\team-task-new.ps1'
$addDelegationScript = Join-Path $root 'scripts\team-task-add-delegation.ps1'
$decisionScript = Join-Path $root 'scripts\team-task-decision.ps1'
$authorizeScript = Join-Path $root 'scripts\team-task-authorize.ps1'
$statusScript = Join-Path $root 'scripts\team-task-status.ps1'
$indexScript = Join-Path $root 'scripts\team-task-index.ps1'
$auditScript = Join-Path $root 'scripts\team-task-audit.ps1'
$reviewGateScript = Join-Path $root 'scripts\team-task-review-gate.ps1'
$commonScript = Join-Path $root 'scripts\common.ps1'
$teamTaskCommonScript = Join-Path $root 'scripts\team-task-common.ps1'

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

function Wait-TestTeamTaskReplaceReady([string]$SignalPath,[int]$TimeoutMilliseconds = 5000) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $SignalPath) { return }
    Start-Sleep -Milliseconds 20
  }
  throw "TEAM_TASK_REPLACE_WINDOW_NOT_READY path=$SignalPath"
}

function Start-TestTeamTaskReplaceWindow([string]$Path,[string]$SignalPath,[int]$HoldMilliseconds = 1200) {
  return Start-Job -ArgumentList $commonScript,$teamTaskCommonScript,$Path,$SignalPath,$HoldMilliseconds -ScriptBlock {
    param($CommonScript,$TeamTaskCommonScript,$RecordPath,$ReadyPath,$DelayMilliseconds)
    . $CommonScript
    . $TeamTaskCommonScript
    Invoke-TeamTaskRecordLock $RecordPath {
      $heldPath = "$RecordPath.test-replace"
      Move-Item -LiteralPath $RecordPath -Destination $heldPath -Force
      Set-Content -LiteralPath $ReadyPath -Value 'ready' -Encoding UTF8
      try {
        Start-Sleep -Milliseconds $DelayMilliseconds
      } finally {
        if (Test-Path -LiteralPath $heldPath) { Move-Item -LiteralPath $heldPath -Destination $RecordPath -Force }
      }
    } | Out-Null
  }
}

function Complete-TestTeamTaskReplaceWindow([object]$Job) {
  try {
    $null = $Job | Wait-Job
    $null = $Job | Receive-Job
    $Job.State | Should Be 'Completed'
  } finally {
    $Job | Remove-Job -Force -ErrorAction SilentlyContinue
  }
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
    $workerCount = 8
    $iterations = 6
    foreach ($iteration in 1..$iterations) {
      $stateRoot = Join-Path $TestDrive "concurrent-state-$iteration"
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

      $failedWorkers = @($workers | Where-Object { $_.exitCode -ne 0 })
      if ($failedWorkers.Count -gt 0) {
        $details = @($failedWorkers | Select-Object worker,exitCode,output | ConvertTo-Json -Compress -Depth 4)
        throw "TEAM_TASK_CONCURRENT_REPORT_FAILURE iteration=$iteration details=$details"
      }
      $failedWorkers.Count | Should Be 0
      $path = Join-Path $stateRoot "workspace\team-tasks\$($created.teamTaskId).json"
      $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
      @($record.delegations).Count | Should Be $workerCount
      @($record.delegations.delegationId | Select-Object -Unique).Count | Should Be $workerCount
      @($record.delegations | Where-Object { $_.delegationId -notmatch '^delegation-\d{8}-\d{9}-[a-f0-9]{32}$' }).Count | Should Be 0
      @($record.expectedJoinSlots | Where-Object { $_.status -eq 'reported' }).Count | Should Be $workerCount
    }
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

  It 'waits through a locked replacement instead of falsely reporting a missing task' {
    $stateRoot = Join-Path $TestDrive 'replacement-reader-state'
    $created = New-TestTeamTask $stateRoot @('slot-a')
    $path = Join-Path $stateRoot "workspace\team-tasks\$($created.teamTaskId).json"

    $statusSignal = Join-Path $stateRoot 'status-replace-ready'
    $statusWindow = Start-TestTeamTaskReplaceWindow $path $statusSignal
    try {
      Wait-TestTeamTaskReplaceReady $statusSignal
      $status = Invoke-TeamTaskJson $statusScript @(
        '-TeamTaskId',$created.teamTaskId,
        '-StateRoot',$stateRoot,
        '-Json'
      )
      $status.exitCode | Should Be 0
      $status.value.teamTaskId | Should Be $created.teamTaskId
    } finally {
      Complete-TestTeamTaskReplaceWindow $statusWindow
    }

    $reportSignal = Join-Path $stateRoot 'report-replace-ready'
    $reportWindow = Start-TestTeamTaskReplaceWindow $path $reportSignal
    try {
      Wait-TestTeamTaskReplaceReady $reportSignal
      $report = Invoke-TeamTaskJson $addDelegationScript @(
        '-TeamTaskId',$created.teamTaskId,
        '-Role','worker-a',
        '-Task','replacement-window report',
        '-JoinSlotId','slot-a',
        '-IdempotencyKey','replacement-window-report',
        '-StateRoot',$stateRoot,
        '-Json'
      )
      $report.exitCode | Should Be 0
      $report.value.delegationId | Should Match '^delegation-\d{8}-\d{9}-[a-f0-9]{32}$'
    } finally {
      Complete-TestTeamTaskReplaceWindow $reportWindow
    }

    @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).delegations).Count | Should Be 1
  }

  It 'does not publish clean derived views while a record replacement is active' {
    $stateRoot = Join-Path $TestDrive 'replacement-scan-state'
    $created = New-TestTeamTask $stateRoot @('slot-a')
    $authorization = Invoke-TeamTaskJson $authorizeScript @(
      '-TeamTaskId',$created.teamTaskId,
      '-Role','code-worker',
      '-Task','unreviewed code task',
      '-AllowedFiles','runtime/*',
      '-ForbiddenFiles','memory/*',
      '-SuccessCriteria','returns evidence',
      '-VerificationCommands','powershell -NoProfile -Command exit 0',
      '-Rollback','revert the change',
      '-StateRoot',$stateRoot,
      '-Json'
    )
    $authorization.exitCode | Should Be 0
    $path = Join-Path $stateRoot "workspace\team-tasks\$($created.teamTaskId).json"
    $cases = @(
      [pscustomobject]@{ name='index'; script=$indexScript; arguments=@('-StateRoot',$stateRoot,'-Json') },
      [pscustomobject]@{ name='audit'; script=$auditScript; arguments=@('-StateRoot',$stateRoot,'-Json') },
      [pscustomobject]@{ name='review-gate'; script=$reviewGateScript; arguments=@('-StateRoot',$stateRoot,'-Json') }
    )

    foreach ($case in $cases) {
      $signal = Join-Path $stateRoot ("$($case.name)-replace-ready")
      $window = Start-TestTeamTaskReplaceWindow $path $signal
      try {
        Wait-TestTeamTaskReplaceReady $signal
        $result = Invoke-TeamTaskJson $case.script $case.arguments
        switch ($case.name) {
          'index' {
            $result.exitCode | Should Be 0
            $result.value.count | Should Be 1
            @($result.value.recent | Where-Object { $_.teamTaskId -eq $created.teamTaskId }).Count | Should Be 1
          }
          'audit' {
            $result.exitCode | Should Be 1
            $result.value.codeCapableDelegationCount | Should Be 1
            $result.value.unreviewedCodeChangeCount | Should Be 1
          }
          'review-gate' {
            $result.exitCode | Should Be 1
            $result.value.teamTaskCount | Should Be 1
            $result.value.blockerCount | Should BeGreaterThan 0
          }
        }
      } finally {
        Complete-TestTeamTaskReplaceWindow $window
      }
    }
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
