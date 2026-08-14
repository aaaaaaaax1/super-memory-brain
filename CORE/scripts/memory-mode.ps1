param(
  # Legacy values remain accepted only to return a clear migration result.
  # They never create or select a second live memory root.
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

function Set-SharedMemoryRootForSkills([string]$SkillRoot, [string]$MemoryRoot) {
  Initialize-SuperBrainMemoryRoot $MemoryRoot $Root 'shared' @('all-agents')
  foreach ($skillName in Get-SuperBrainSkillNames) {
    $skillDir = Join-Path $SkillRoot $skillName
    if (Test-Path $skillDir) {
      Write-SuperBrainPackageRootMarker $skillDir $Root
      Write-SuperBrainMemoryRootMarker $skillDir $MemoryRoot
      Write-Host "MEMORY_MODE_MARKER skill=$skillName root=$SkillRoot memoryRootMarker=$MemoryRootMarkerName memory=$MemoryRoot scope=shared"
    }
  }
}

$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root

if ($Mode -eq 'Status') {
  $policy = Get-SuperBrainSharingPolicy $Root
  Write-Host "MEMORY_SHARING_POLICY initialized=$($policy.initialized) mode=shared activeRoot=$sharedRoot sharedRoot=$sharedRoot agentsRoot=$($policy.agentsRoot) groupsRoot=$($policy.groupsRoot) legacyRootsReadOnly=True"
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
        $shared = Test-SuperBrainSamePath ([string]$mem.actual) $sharedRoot
        Write-Host "MEMORY_MODE_STATUS skill=$skillName root=$skillRoot packageRootOk=$($pkg.ok) memoryRootOk=$($mem.ok) sharedRootOk=$shared memoryRootMarker=$MemoryRootMarkerName scope=$scope memory=$($mem.actual)"
      }
    }
  }
  exit 0
}

if ($Mode -ne 'Shared') {
  Write-Host "MEMORY_MODE_RETIRED requested=$Mode resolved=Shared reason=single-super-brain-memory-authority"
}

if ($Target -in @('ZCode','Both')) { Set-SharedMemoryRootForSkills $ZCodeSkills $sharedRoot }
if ($Target -in @('Codex','Both')) { Set-SharedMemoryRootForSkills $CodexSkills $sharedRoot }
Write-SuperBrainSharingPolicy $Root 'shared' $sharedRoot @('all-agents') | Out-Null
Write-Host "MEMORY_MODE_OK mode=Shared target=$Target memory=$sharedRoot policy=$(Get-SuperBrainSharingPolicyPath $Root) legacyRootsReadOnly=True"
exit 0
