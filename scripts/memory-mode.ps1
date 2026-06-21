param(
  [ValidateSet('Status','Shared','SplitMemory','Agent','Group')]
  [string]$Mode = 'Status',
  [string]$AgentName = '',
  [string]$GroupName = '',
  [ValidateSet('ZCode','Codex','Both')]
  [string]$Target = 'Both',
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills"
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRootMarkerName = 'memory-root.txt'
$MemoryScopeName = '.memory-scope.json'

function Set-MemoryRootForSkills([string]$SkillRoot, [string]$MemoryRoot, [string]$Scope = 'custom', [string[]]$Members = @()) {
  Initialize-SuperBrainMemoryRoot $MemoryRoot $Root $Scope $Members
  foreach ($skillName in Get-SuperBrainSkillNames) {
    $skillDir = Join-Path $SkillRoot $skillName
    if (Test-Path $skillDir) {
      Write-SuperBrainPackageRootMarker $skillDir $Root
      Write-SuperBrainMemoryRootMarker $skillDir $MemoryRoot
      Write-Host "MEMORY_MODE_MARKER skill=$skillName root=$SkillRoot memoryRootMarker=$MemoryRootMarkerName memory=$MemoryRoot"
    }
  }
}

if ($Mode -eq 'Status') {
  $policy = Get-SuperBrainSharingPolicy $Root
  Write-Host "MEMORY_SHARING_POLICY initialized=$($policy.initialized) mode=$($policy.mode) activeRoot=$($policy.activeRoot) sharedRoot=$($policy.sharedRoot) agentsRoot=$($policy.agentsRoot) groupsRoot=$($policy.groupsRoot)"
  foreach ($skillRoot in @($ZCodeSkills,$CodexSkills)) {
    foreach ($skillName in Get-SuperBrainSkillNames) {
      $skillDir = Join-Path $skillRoot $skillName
      if (Test-Path $skillDir) {
        $pkg = Test-SuperBrainPackageRootMarker $skillDir $Root
        $mem = Test-SuperBrainMemoryRootMarker $skillDir
        $scopePath = if ([string]::IsNullOrWhiteSpace($mem.actual)) { '' } else { Join-Path $mem.actual $MemoryScopeName }
        $scope = ''
        if (-not [string]::IsNullOrWhiteSpace($scopePath) -and (Test-Path $scopePath)) {
          try { $scope = (Get-Content -LiteralPath $scopePath -Raw -Encoding UTF8 | ConvertFrom-Json).scope } catch { $scope = 'invalid' }
        }
        Write-Host "MEMORY_MODE_STATUS skill=$skillName root=$skillRoot packageRootOk=$($pkg.ok) memoryRootOk=$($mem.ok) memoryRootMarker=$MemoryRootMarkerName scope=$scope memory=$($mem.actual)"
      }
    }
  }
  exit 0
}

if ($Mode -eq 'Shared') {
  $memoryRoot = Get-SuperBrainSharedMemoryRoot $Root
  if ($Target -in @('ZCode','Both')) { Set-MemoryRootForSkills $ZCodeSkills $memoryRoot 'shared' @('zcode','codex','all-agents') }
  if ($Target -in @('Codex','Both')) { Set-MemoryRootForSkills $CodexSkills $memoryRoot 'shared' @('zcode','codex','all-agents') }
  Write-SuperBrainSharingPolicy $Root 'shared' $memoryRoot @('all-agents') | Out-Null
  Write-Host "MEMORY_MODE_OK mode=Shared target=$Target memory=$memoryRoot policy=$(Get-SuperBrainSharingPolicyPath $Root)"
  exit 0
}

if ($Mode -eq 'SplitMemory') {
  $zMemory = Get-SuperBrainAgentMemoryRoot 'zcode' $Root
  $codexMemory = Get-SuperBrainAgentMemoryRoot 'codex' $Root
  if ($Target -in @('ZCode','Both')) { Set-MemoryRootForSkills $ZCodeSkills $zMemory 'agent' @('zcode') }
  if ($Target -in @('Codex','Both')) { Set-MemoryRootForSkills $CodexSkills $codexMemory 'agent' @('codex') }
  $activeRoot = if ($Target -eq 'Codex') { $codexMemory } else { $zMemory }
  Write-SuperBrainSharingPolicy $Root 'split' $activeRoot @('zcode','codex') | Out-Null
  Write-Host "MEMORY_MODE_OK mode=SplitMemory target=$Target zcode=$zMemory codex=$codexMemory policy=$(Get-SuperBrainSharingPolicyPath $Root)"
  exit 0
}

if ($Mode -eq 'Group') {
  if ([string]::IsNullOrWhiteSpace($GroupName)) { throw 'Group mode requires -GroupName.' }
  $groupMemory = Get-SuperBrainGroupMemoryRoot $GroupName $Root
  $members = @()
  if ($Target -in @('ZCode','Both')) { $members += 'zcode'; Set-MemoryRootForSkills $ZCodeSkills $groupMemory 'group' @($GroupName,'zcode') }
  if ($Target -in @('Codex','Both')) { $members += 'codex'; Set-MemoryRootForSkills $CodexSkills $groupMemory 'group' @($GroupName,'codex') }
  Write-SuperBrainSharingPolicy $Root 'group' $groupMemory @($members) | Out-Null
  Write-Host "MEMORY_MODE_OK mode=Group target=$Target group=$GroupName memory=$groupMemory policy=$(Get-SuperBrainSharingPolicyPath $Root)"
  exit 0
}

if ([string]::IsNullOrWhiteSpace($AgentName)) { throw 'Agent mode requires -AgentName.' }
$agentMemory = Get-SuperBrainAgentMemoryRoot $AgentName $Root
if ($Target -in @('ZCode','Both')) { Set-MemoryRootForSkills $ZCodeSkills $agentMemory 'agent' @($AgentName) }
if ($Target -in @('Codex','Both')) { Set-MemoryRootForSkills $CodexSkills $agentMemory 'agent' @($AgentName) }
Write-SuperBrainSharingPolicy $Root 'agent' $agentMemory @($AgentName) | Out-Null
Write-Host "MEMORY_MODE_OK mode=Agent target=$Target agent=$AgentName memory=$agentMemory policy=$(Get-SuperBrainSharingPolicyPath $Root)"
exit 0
