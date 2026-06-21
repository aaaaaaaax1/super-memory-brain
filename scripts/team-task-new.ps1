param(
  [Parameter(Mandatory=$true)][string]$Goal,
  [ValidateSet('direct','single_delegate','team_parallel','review_board')][string]$DispatchLevel = 'single_delegate',
  [int]$DispatchScore = 0,
  [string[]]$DispatchReason = @(),
  [string]$Template = '',
  [switch]$AutoTemplate,
  [string[]]$Constraints = @(),
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$teamRoot = Join-Path $workspace 'team-tasks'
New-Item -ItemType Directory -Force -Path $teamRoot | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$id = "team-$stamp"
$path = Join-Path $teamRoot "$id.json"
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

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
  delegations = @()
  commanderDecision = [pscustomobject]@{
    status = 'pending'
    adoptedFindings = @()
    rejectedFindings = @()
    conflicts = @()
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

Write-JsonUtf8NoBom $path $record 12
& (Join-Path $PSScriptRoot 'team-task-index.ps1') | Out-Null

$result = [pscustomobject]@{
  ok = $true
  teamTaskId = $id
  path = $path
  record = $record
}

if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "TEAM_TASK_CREATED id=$id path=$path" }
exit 0
