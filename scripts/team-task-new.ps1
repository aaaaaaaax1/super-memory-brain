param(
  [Parameter(Mandatory=$true)][string]$Goal,
  [ValidateSet('direct','single_delegate','team_parallel','review_board')][string]$DispatchLevel = 'single_delegate',
  [int]$DispatchScore = 0,
  [string[]]$DispatchReason = @(),
  [string]$Template = '',
  [switch]$AutoTemplate,
  [string[]]$Constraints = @(),
  [string[]]$ExpectedJoinSlots = @(),
  [string]$StateRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'team-task-common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Get-TeamTaskWorkspace $Root $StateRoot
$teamRoot = Join-Path $workspace 'team-tasks'
New-Item -ItemType Directory -Force -Path $teamRoot | Out-Null

$selectedTemplate = $null
if ($Template) {
  $templateListJson = & (Join-Path $PSScriptRoot 'team-template-list.ps1') -Json
  $templateList = $templateListJson | ConvertFrom-Json
  $selectedTemplate = @($templateList.templates | Where-Object { $_.id -eq $Template -or $_.name -eq $Template } | Select-Object -First 1)[0]
  if (-not $selectedTemplate) { throw "Team template not found: $Template" }
} elseif ($AutoTemplate) {
  $selectJson = & (Join-Path $PSScriptRoot 'team-template-select.ps1') -DispatchLevel $DispatchLevel -Reason $DispatchReason -Json
  $selection = $selectJson | ConvertFrom-Json
  if ($selection.selected) { $selectedTemplate = $selection.selected }
}

$teamTemplate = if ($selectedTemplate) {
  [pscustomobject]@{
    id = $selectedTemplate.id
    name = $selectedTemplate.name
    roles = @($selectedTemplate.roles)
    selectedBy = if ($AutoTemplate) { 'team-template-select.ps1' } else { 'team-task-new.ps1 -Template' }
    overrideReason = ''
  }
} else { $null }

$requestedJoinSlots = @($ExpectedJoinSlots)
if ($requestedJoinSlots.Count -eq 0 -and $DispatchLevel -eq 'team_parallel' -and $teamTemplate) {
  $requestedJoinSlots = @($teamTemplate.roles)
}
$normalizedJoinSlots = @(ConvertTo-TeamTaskJoinSlots $requestedJoinSlots)
if ($DispatchLevel -eq 'team_parallel' -and $normalizedJoinSlots.Count -eq 0) {
  throw 'TEAM_TASK_JOIN_SLOTS_REQUIRED'
}

$created = Invoke-SuperBrainFileLock (Join-Path $teamRoot '.team-task-create') {
  for ($attempt = 1; $attempt -le 16; $attempt++) {
    $id = New-TeamTaskIdentity 'team'
    $path = Join-Path $teamRoot "$id.json"
    if (Test-Path -LiteralPath $path) { continue }
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $record = [pscustomobject]@{
      schemaVersion = '1.0'
      teamTaskId = $id
      createdAt = $now
      updatedAt = $now
      commander = 'main-agent'
      userGoal = $Goal
      dispatchLevel = $DispatchLevel
      dispatchScore = $DispatchScore
      dispatchReason = @($DispatchReason)
      constraints = @($Constraints)
      teamTemplate = $teamTemplate
      expectedJoinSlots = @($normalizedJoinSlots)
      delegations = @()
      commanderDecision = [pscustomobject]@{
        status = 'pending'
        adoptedFindings = @()
        rejectedFindings = @()
        conflicts = @()
        integratedJoinSlots = @()
        integratedDelegationIds = @()
        join = [pscustomobject]@{
          required = ($DispatchLevel -eq 'team_parallel' -or $normalizedJoinSlots.Count -gt 0)
          expectedSlotCount = $normalizedJoinSlots.Count
          terminalSlotCount = 0
          integratedSlotCount = 0
          status = 'pending'
          blockers = @()
        }
        reason = ''
      }
      verification = [pscustomobject]@{
        status = 'pending'
        commands = @()
        evidence = @()
        risks = @()
      }
      memoryAdmission = [pscustomobject]@{
        writeLongTerm = $false
        acceptedFacts = @()
        reason = 'Pending verification'
      }
    }
    Write-TeamTaskRecordUnlocked $path $record 14
    return [pscustomobject]@{ teamTaskId=$id; path=$path; record=$record }
  }
  throw 'TEAM_TASK_ID_GENERATION_FAILED'
}

Update-TeamTaskIndex $PSScriptRoot $StateRoot | Out-Null

$result = [pscustomobject]@{
  ok = $true
  teamTaskId = $created.teamTaskId
  path = $created.path
  record = $created.record
}

if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "TEAM_TASK_CREATED id=$id path=$path" }
exit 0
