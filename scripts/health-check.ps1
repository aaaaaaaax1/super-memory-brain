param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$MemoryRoot = "",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills"
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root }
$MemoryScripts = Join-Path $MemoryRoot 'scripts'
$ok = $true

function Check-Path([string]$Path) {
  if (Test-Path $Path) { Write-Host "OK $Path" } else { Write-Host "MISSING $Path"; $script:ok = $false }
}

$paths = @(
  (Join-Path $ZCodeSkills 'super-memory-brain\SKILL.md'),
  (Join-Path $ZCodeSkills 'skill-orchestrator\SKILL.md'),
  (Join-Path $ZCodeSkills 'plusunm-g1\SKILL.md'),
  (Join-Path $ZCodeSkills 'nexsandglass-dedicated-memory\SKILL.md'),
  (Join-Path $MemoryScripts 'sandglass_log.py'),
  (Join-Path $MemoryScripts 'sandglass_vault.py'),
  (Join-Path $MemoryScripts 'sandglass_mcp.py')
)
foreach ($path in $paths) { Check-Path $path }

foreach ($skillRoot in @($ZCodeSkills,$CodexSkills)) {
  foreach ($skillName in Get-SuperBrainSkillNames) {
    $skillDir = Join-Path $skillRoot $skillName
    $pkg = Test-SuperBrainPackageRootMarker $skillDir $Root
    $mem = Test-SuperBrainMemoryRootMarker $skillDir
    if ($pkg.ok -and $mem.ok) { Write-Host "OK ROOT_MARKERS $skillName $skillRoot memory=$($mem.actual)" } else { Write-Host "MISSING ROOT_MARKERS $skillName $skillRoot package=$($pkg.ok) memory=$($mem.ok)"; $ok = $false }
  }
}

& (Join-Path $PSScriptRoot 'startup-check.ps1') -ZCodeSkills $ZCodeSkills -CodexSkills $CodexSkills -MemoryRoot $MemoryRoot
if ($LASTEXITCODE -ne 0) { Write-Host 'MISSING startup hook/config readiness'; $ok = $false }

$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts
python -c "from sandglass_vault import recent; print(recent(3))"
if ($LASTEXITCODE -ne 0) { Write-Host 'MISSING NexSandglass python runtime'; $ok = $false }

if ($ok) { Write-Host 'HEALTH_CHECK_OK' } else { Write-Host 'HEALTH_CHECK_FAILED'; exit 1 }
