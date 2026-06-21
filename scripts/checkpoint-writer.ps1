param(
  [ValidateSet('Start','Complete','Clear','Get')]
  [string]$Action = 'Get',
  [string]$TaskId = '',
  [string]$SessionId = '',
  [string]$Agent = 'super-memory-brain',
  [string]$Platform = 'zcode',
  [string]$CurrentStep = '',
  [string]$NextAction = '',
  [string[]]$Blockers = @(),
  [string[]]$Evidence = @(),
  [string]$Source = '',
  [string]$Status = 'active',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
New-Item -ItemType Directory -Force -Path $workspace | Out-Null
$path = Join-Path $workspace 'active-checkpoint.json'

function Read-Checkpoint {
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

switch ($Action) {
  'Get' {
    $current = Read-Checkpoint
    if ($Json) {
      if ($null -eq $current) { 'null' } else { $current | ConvertTo-Json -Depth 8 }
    } else {
      if ($null -eq $current) { Write-Host 'CHECKPOINT none' } else { Write-Host "CHECKPOINT status=$($current.status) taskId=$($current.taskId) step=$($current.currentStep)" }
    }
    exit 0
  }
  'Clear' {
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
    if ($Json) { [pscustomobject]@{ ok=$true; action='Clear'; path=$path } | ConvertTo-Json -Depth 6 } else { Write-Host "CHECKPOINT_CLEARED path=$path" }
    exit 0
  }
  'Start' {
    if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = 'task-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    $checkpoint = [pscustomobject]@{
      ok = $true
      action = 'Start'
      taskId = $TaskId
      sessionId = $SessionId
      agent = $Agent
      platform = $Platform
      timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      status = if ([string]::IsNullOrWhiteSpace($Status)) { 'active' } else { $Status }
      source = $Source
      currentStep = $CurrentStep
      blockers = @($Blockers)
      nextAction = $NextAction
      evidence = @($Evidence)
    }
    Write-JsonUtf8NoBom $path $checkpoint 8
    if ($Json) { $checkpoint | ConvertTo-Json -Depth 8 } else { Write-Host "CHECKPOINT_STARTED taskId=$TaskId step=$CurrentStep" }
    exit 0
  }
  'Complete' {
    $current = Read-Checkpoint
    $checkpoint = [pscustomobject]@{
      ok = $true
      action = 'Complete'
      taskId = if ($TaskId) { $TaskId } elseif ($current) { $current.taskId } else { '' }
      sessionId = if ($SessionId) { $SessionId } elseif ($current) { $current.sessionId } else { '' }
      agent = if ($Agent) { $Agent } elseif ($current) { $current.agent } else { 'super-memory-brain' }
      platform = if ($Platform) { $Platform } elseif ($current) { $current.platform } else { 'zcode' }
      timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      status = 'completed'
      source = if ($Source) { $Source } elseif ($current) { $current.source } else { '' }
      currentStep = $CurrentStep
      blockers = @($Blockers)
      nextAction = $NextAction
      evidence = @($Evidence)
      supersedes = if ($current) { $current.taskId } else { '' }
    }
    Write-JsonUtf8NoBom (Join-Path $workspace 'last-completed-checkpoint.json') $checkpoint 8
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
    if ($Json) { $checkpoint | ConvertTo-Json -Depth 8 } else { Write-Host "CHECKPOINT_COMPLETED taskId=$($checkpoint.taskId)" }
    exit 0
  }
}
