[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Summary = '',
  [string[]]$Changed = @(),
  [string[]]$Commands = @(),
  [string[]]$Risks = @(),
  [string[]]$Evidence = @(),
  [string[]]$NextSteps = @(),
  [string]$TeamTaskId = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$path = Join-Path $workspace 'last-task-verification.json'

function Read-WorkspaceJson([string]$Name) {
  $candidate = Join-Path $workspace $Name
  if (-not (Test-Path $candidate)) { return $null }
  try { return Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastRelease = Read-WorkspaceJson 'last-release.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$teamTask = $null
if ($TeamTaskId) {
  $teamPath = Join-Path (Join-Path $workspace 'team-tasks') "$TeamTaskId.json"
  if (Test-Path $teamPath) {
    try { $teamTask = Get-Content -LiteralPath $teamPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $teamTask = $null }
  }
}
$lastDoctor = $null
$doctorRiskSummary = $null
$doctorRisks = @()
try {
  $doctorJson = & (Join-Path $PSScriptRoot 'doctor.ps1') -Json
  if ($LASTEXITCODE -eq 0) {
    $lastDoctor = $doctorJson | ConvertFrom-Json
    $doctorRiskSummary = $lastDoctor.riskSummary
    $doctorRisks = @($lastDoctor.risks)
  }
} catch {}
$verification = [pscustomobject]@{
  ok = (($lastVerify -and $lastVerify.ok -eq $true) -and ($lastHotRefresh -and $lastHotRefresh.ok -eq $true) -and ($null -eq $lastDoctor -or $lastDoctor.ok -eq $true))
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  version = (Get-SuperBrainManifest $Root).version
  summary = $Summary
  changed = @($Changed)
  commands = @($Commands)
  risks = @($Risks)
  evidence = @($Evidence)
  nextSteps = @($NextSteps)
  teamTask = if ($teamTask) { [pscustomobject]@{ teamTaskId=$teamTask.teamTaskId; dispatchLevel=$teamTask.dispatchLevel; delegationCount=@($teamTask.delegations).Count; decisionStatus=$teamTask.commanderDecision.status; verificationStatus=$teamTask.verification.status } } else { $null }
  doctor = if ($lastDoctor) { [pscustomobject]@{ ok=$lastDoctor.ok; riskSummary=$doctorRiskSummary; risks=@($doctorRisks | Select-Object -First 10) } } else { $null }
  lastVerify = if ($lastVerify) { [pscustomobject]@{ ok=$lastVerify.ok; checkedAt=$lastVerify.checkedAt; version=$lastVerify.version } } else { $null }
  lastRelease = if ($lastRelease) { [pscustomobject]@{ ok=$lastRelease.ok; checkedAt=$lastRelease.checkedAt; destination=$lastRelease.destination } } else { $null }
  lastHotRefresh = if ($lastHotRefresh) { [pscustomobject]@{ ok=$lastHotRefresh.ok; checkedAt=$lastHotRefresh.checkedAt } } else { $null }
}
if ($verification.ok) {
  try { & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Complete -Source 'task-verification.ps1' -CurrentStep $Summary -NextAction ((@($NextSteps) -join '; ')) -Evidence @($Evidence) | Out-Null } catch {}
}
Write-JsonUtf8NoBom $path $verification 8
if ($Json) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 } else { Write-Host "TASK_VERIFICATION_OK path=$path ok=$($verification.ok)" }
if (-not $verification.ok) { exit 1 }
exit 0
