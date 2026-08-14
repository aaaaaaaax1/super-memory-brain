[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Snapshot','Status','StartTask','AddStep','CompleteStep','SkipStep','CompleteTask','ArchiveTask','ClearTask','AddFinding','AdmitFinding','RejectFinding')]
  [string]$Action = 'Snapshot',
  [string]$Goal = '',
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [string]$Step = '',
  [string]$StepId = '',
  [string]$Evidence = '',
  [string[]]$RelatedFiles = @(),
  [string[]]$VerificationCommands = @(),
  [string[]]$Risks = @(),
  [string]$Agent = '',
  [string]$Finding = '',
  [string]$Source = '',
  [string]$FindingId = '',
  [string]$Reason = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$workspaceKeyValue = Get-SuperBrainWorkspaceKey $WorkspaceKey
$taskIdValue = ([string]$TaskId).Trim()

function Limit-ProjectContinuityText([string]$Value,[int]$Max = 220) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ($Value -replace '\s+',' ').Trim()
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Write-ProjectContinuityResult([object]$Result,[int]$ExitCode = 0) {
  if ($Json) { $Result | ConvertTo-Json -Depth 10 }
  else { Write-Host "PROJECT_CONTINUITY action=$($Result.action) status=$($Result.status) code=$($Result.code)" }
  exit $ExitCode
}

if ($Action -eq 'Status') {
  $context = Get-SuperBrainCurrentTaskContext $workspace $workspaceKeyValue
  if ([string]::IsNullOrWhiteSpace($taskIdValue) -and $context -and $context.PSObject.Properties['taskId']) { $taskIdValue = [string]$context.taskId }
  $contract = $null
  $contractCode = 'not_found'
  try {
    $args = @{ Action='Resolve'; WorkspaceKey=$workspaceKeyValue; NoExit=$true; Json=$true }
    if (-not [string]::IsNullOrWhiteSpace($taskIdValue)) { $args.TaskId = $taskIdValue }
    $raw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') @args 2>$null)
    if (@($raw).Count -gt 0) { $contract = (($raw -join "`n") | ConvertFrom-Json) }
    if ($contract -and $contract.PSObject.Properties['code']) { $contractCode = [string]$contract.code }
  } catch { $contractCode = 'resolution_error' }
  $result = [pscustomobject]@{
    ok = $true
    schema = 'super-brain.project-continuity-retirement.v1'
    action = 'Status'
    status = 'retired_read_only'
    code = 'PROJECT_CONTINUITY_LEGACY_WRITER_RETIRED'
    taskId = Limit-ProjectContinuityText $taskIdValue 160
    workspaceKey = $workspaceKeyValue
    canonicalOwner = 'execution-contract.ps1 + TaskStateStore'
    executionContract = [pscustomobject]@{
      available = ($contract -and $contract.ok -eq $true)
      code = $contractCode
      actionAuthorization = if($contract -and $contract.PSObject.Properties['actionAuthorization']){[string]$contract.actionAuthorization}else{'not_applicable'}
      nextAction = ''
    }
    guard = 'project-continuity is a retired direct legacy writer. Status is read-only; canonical task state, checkpoints, decisions, and completion receipts are owned by execution-contract.ps1 and TaskStateStore.'
    nextAction = 'Use execution-contract, checkpoint-writer, task-state-store, and status-snapshot-writer for current task state. Do not recreate task-graph.json or step-ledger.json projections.'
  }
  Write-ProjectContinuityResult $result 0
}

$result = [pscustomobject]@{
  ok = $false
  schema = 'super-brain.project-continuity-retirement.v1'
  action = $Action
  status = 'retired_error'
  code = 'PROJECT_CONTINUITY_LEGACY_WRITER_RETIRED'
  taskId = Limit-ProjectContinuityText $taskIdValue 160
  workspaceKey = $workspaceKeyValue
  canonicalOwner = 'execution-contract.ps1 + TaskStateStore'
  guard = 'The old project graph, step-ledger, candidate-finding, and task-archive write paths are retired. A direct legacy mutation would create a second state authority and is therefore blocked.'
  nextAction = 'Use task-scoped execution-contract/checkpoint-writer operations; use TaskStateStore for governed lifecycle changes.'
}
Write-ProjectContinuityResult $result 1
