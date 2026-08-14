$Root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ContractScript=Join-Path $Root 'scripts\execution-contract.ps1'

function Invoke-TaskInstanceContract($Arguments) {
  $raw=@(& $ContractScript @Arguments 2>&1)
  $value=(($raw-join"`n")|ConvertFrom-Json)
  return [pscustomobject]@{exitCode=if($value.ok-eq$true){0}else{1};value=$value}
}

Describe 'Execution contract task instance binding' {
  It 'keeps one random instance across updates and rotates it after clear and recreation' {
    $stateRoot=Join-Path $TestDrive 'task-instance-lifecycle'
    $taskId='task-instance-lifecycle'
    $workspaceKey='ws-777777777777777777777777'
    $sessionKey='sid-7777777777777777'
    $first=Invoke-TaskInstanceContract @{Action='Set';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;FocusId='main';LatestUserInstruction='start task';NextAction='step one';StateRoot=$stateRoot;NoExit=$true;Json=$true}
    $first.exitCode|Should Be 0
    $first.value.taskInstanceId|Should Match '^ti-[a-f0-9]{32}$'

    $updated=Invoke-TaskInstanceContract @{Action='Set';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;FocusId='main';LatestUserInstruction='continue task';NextAction='step two';ExpectedRevision=[int]$first.value.revision;ExpectedPlanFingerprint=[string]$first.value.planReceipt.planFingerprint;TransitionId='task-instance-update';StateRoot=$stateRoot;NoExit=$true;Json=$true}
    $updated.exitCode|Should Be 0
    $updated.value.taskInstanceId|Should Be $first.value.taskInstanceId

    $cleared=Invoke-TaskInstanceContract @{Action='Clear';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;ExpectedRevision=[int]$updated.value.revision;ExpectedPlanFingerprint=[string]$updated.value.planReceipt.planFingerprint;TransitionId='task-instance-clear';StateRoot=$stateRoot;NoExit=$true;Json=$true}
    $cleared.exitCode|Should Be 0
    $cleared.value.removed|Should Be $true

    $recreated=Invoke-TaskInstanceContract @{Action='Set';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;FocusId='main';LatestUserInstruction='new task instance';NextAction='new step';StateRoot=$stateRoot;NoExit=$true;Json=$true}
    $recreated.exitCode|Should Be 0
    $recreated.value.taskInstanceId|Should Match '^ti-[a-f0-9]{32}$'
    $recreated.value.taskInstanceId|Should Not Be $first.value.taskInstanceId
  }
}
