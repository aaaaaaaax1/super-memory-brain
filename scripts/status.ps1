param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$MemoryRoot = "",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) {
  $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
}
$MemoryScripts = Join-Path $MemoryRoot 'scripts'
$hook = Get-SuperBrainHookPath ''
$ok = $true
$checks = @()

function Add-MarkerCheck([string]$Name, [object]$Result) {
  if (-not $Result.ok) { $script:ok = $false }
  $script:checks += [pscustomobject]@{ name=$Name; ok=$Result.ok; path=$Result.marker; actual=$Result.actual; expected=$Result.expected }
}

function Add-Check([string]$Name, [string]$Path) {
  $exists = Test-Path $Path
  if (-not $exists) { $script:ok = $false }
  $script:checks += [pscustomobject]@{
    name = $Name
    ok = $exists
    path = $Path
  }
}

Add-Check 'Super Memory Brain' (Join-Path $ZCodeSkills 'super-memory-brain\SKILL.md')
Add-Check 'ORC / skill-orchestrator' (Join-Path $ZCodeSkills 'skill-orchestrator\SKILL.md')
Add-Check 'G1 / plusunm-g1' (Join-Path $ZCodeSkills 'plusunm-g1\SKILL.md')
Add-Check 'NexSandglass skill' (Join-Path $ZCodeSkills 'nexsandglass-dedicated-memory\SKILL.md')
foreach ($skillName in Get-SuperBrainSkillNames) {
  Add-MarkerCheck "ZCode $skillName package root" (Test-SuperBrainPackageRootMarker (Join-Path $ZCodeSkills $skillName) $Root)
  Add-MarkerCheck "ZCode $skillName memory root" (Test-SuperBrainMemoryRootMarker (Join-Path $ZCodeSkills $skillName))
  Add-MarkerCheck "Codex $skillName package root" (Test-SuperBrainPackageRootMarker (Join-Path $CodexSkills $skillName) $Root)
  Add-MarkerCheck "Codex $skillName memory root" (Test-SuperBrainMemoryRootMarker (Join-Path $CodexSkills $skillName))
}
Add-Check 'Package memory root' $MemoryRoot
Add-Check 'NexSandglass runtime log' (Join-Path $MemoryScripts 'sandglass_log.py')
Add-Check 'NexSandglass runtime vault' (Join-Path $MemoryScripts 'sandglass_vault.py')
Add-Check 'Session-start hook' $hook

$hookChecks = @()
if (Test-Path $hook) {
  $hookText = Get-Content -LiteralPath $hook -Raw -Encoding UTF8
  foreach ($item in @(
    @{ name = 'Hook startup rule'; needles = @('SuperBrain:', 'Super Brain default:', 'Default Super Brain startup rule'); requireAll = $false },
    @{ name = 'Hook mandatory skill load'; needles = @('load super-memory-brain for recall/status', 'load Skill super-memory-brain first', 'Load Skill super-memory-brain first'); requireAll = $false },
    @{ name = 'Hook memory policy'; needles = @('memory:auto', 'stable state only', 'Memory shortcut:'); requireAll = $false },
    @{ name = 'Hook recall trigger'; needles = @('semantic/keyword recall', 'state/version/progress/remember/previous-session', 'Recall previous', 'Recall trigger:'); requireAll = $false },
    @{ name = 'Hook short router'; needles = @('G1 governs', 'ORC routes', 'Sandglass only on semantic/keyword recall'); requireAll = $true }
  )) {
    $found = [bool]$item.requireAll
    foreach ($needle in $item.needles) {
      $hasNeedle = ($hookText -like "*$needle*")
      if ($item.requireAll) {
        if (-not $hasNeedle) { $found = $false; break }
      } elseif ($hasNeedle) {
        $found = $true; break
      }
    }
    if (-not $found) { $ok = $false }
    $hookChecks += [pscustomobject]@{
      name = $item.name
      ok = $found
    }
  }
}

$startupCheck = $null
try {
  $startupJsonText = & (Join-Path $PSScriptRoot 'startup-check.ps1') -ZCodeSkills $ZCodeSkills -CodexSkills $CodexSkills -MemoryRoot $MemoryRoot -Json
  $startupCheck = $startupJsonText | ConvertFrom-Json
  if ($startupCheck.ok -ne $true) { $ok = $false }
} catch {
  $startupCheck = [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
  $ok = $false
}

$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts
$recent = ''
try {
  $recent = python -c "from sandglass_vault import recent; print(recent(3))"
  if ($LASTEXITCODE -ne 0) { $ok = $false }
} catch {
  $recent = $_.Exception.Message
  $ok = $false
}

if ($Json) {
  [pscustomobject]@{
    ok = $ok
    packageRoot = $Root
    memoryRoot = $MemoryRoot
    checks = $checks
    hookChecks = $hookChecks
    startupCheck = $startupCheck
    recentMemory = $recent
  } | ConvertTo-Json -Depth 5
} else {
  foreach ($check in $checks) {
    if ($check.ok) { Write-Host "$($check.name): OK - $($check.path)" } else { Write-Host "$($check.name): MISSING - $($check.path)" }
  }
  foreach ($check in $hookChecks) {
    if ($check.ok) { Write-Host "$($check.name): OK" } else { Write-Host "$($check.name): MISSING" }
  }
  if ($startupCheck -and $startupCheck.ok -eq $true) { Write-Host 'Startup auto-check: OK' } else { Write-Host 'Startup auto-check: FAILED' }
  Write-Host "Recent memory: $recent"
  if ($ok) { Write-Host 'STATUS_OK' } else { Write-Host 'STATUS_FAILED' }
}

if (-not $ok) { exit 1 }
exit 0