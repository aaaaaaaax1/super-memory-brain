param(
  [Parameter(Mandatory=$true)]
  [string]$AgentName,
  [Parameter(Mandatory=$true)]
  [string]$SkillRoot,
  [ValidateSet('Agent','Shared','Group')]
  [string]$Mode = 'Shared',
  [string]$GroupName = '',
  [switch]$NoBackup
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$agent = Get-SafeSuperBrainName $AgentName 'agent'

if ($Mode -eq 'Shared') {
  $memoryRoot = Get-SuperBrainSharedMemoryRoot $Root
  $scope = 'shared'
  $members = @('all-agents')
  Write-SuperBrainSharingPolicy $Root 'shared' $memoryRoot @('all-agents') | Out-Null
} elseif ($Mode -eq 'Group') {
  if ([string]::IsNullOrWhiteSpace($GroupName)) { throw 'Group mode requires -GroupName.' }
  $memoryRoot = Get-SuperBrainGroupMemoryRoot $GroupName $Root
  $scope = 'group'
  $members = @((Get-SafeSuperBrainName $GroupName 'group'), $agent)
  Write-SuperBrainSharingPolicy $Root 'group' $memoryRoot @($members) | Out-Null
} else {
  $memoryRoot = Get-SuperBrainAgentMemoryRoot $agent $Root
  $scope = 'agent'
  $members = @($agent)
  Write-SuperBrainSharingPolicy $Root 'agent' $memoryRoot @($agent) | Out-Null
}

Initialize-SuperBrainMemoryRoot $memoryRoot $Root $scope $members
New-Item -ItemType Directory -Force -Path $SkillRoot | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

foreach ($item in Get-SuperBrainSourceItems) {
  $source = Join-Path $Root $item.source
  $dest = Join-Path $SkillRoot $item.name
  if ((Test-Path $dest) -and -not $NoBackup) {
    $backup = Join-Path $Root ("install-backup-$timestamp\agent-$agent\$($item.name)")
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
    Copy-Item -LiteralPath $dest -Destination $backup -Recurse -Force
    Write-Host "Backup skill: $dest -> $backup"
  }
  if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
  Write-SuperBrainPackageRootMarker $dest $Root
  Write-SuperBrainMemoryRootMarker $dest $memoryRoot
  Write-Host "AGENT_SKILL_INSTALLED agent=$agent skill=$($item.name) dest=$dest memory=$memoryRoot scope=$scope"
}

foreach ($path in @(Write-SuperBrainGlobalStartup $SkillRoot $Root -NoBackup:$NoBackup)) { Write-Host "AGENT_GLOBAL_STARTUP_WRITTEN agent=$agent path=$path" }
Write-Host "AGENT_INSTALL_OK agent=$agent mode=$Mode skillRoot=$SkillRoot memory=$memoryRoot policy=$(Get-SuperBrainSharingPolicyPath $Root)"

