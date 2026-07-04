param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$MemoryRoot = "",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [switch]$Json,
  [switch]$DetailedJson
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
    @{ name = 'Hook silent memory auto'; needles = @('memory:auto silent', 'no G1 for ok/chat/code'); requireAll = $true },
    @{ name = 'Hook lightweight continuation recall'; needles = @('continue/previous/remember -> light recall if state needed', 'semantic/keyword recall'); requireAll = $false },
    @{ name = 'Hook recall trigger'; needles = @('semantic/keyword recall', 'state/version/progress/remember/previous-session', 'Recall previous', 'Recall trigger:'); requireAll = $false },
    @{ name = 'Hook short router'; needles = @('ORC routes', 'Sandglass on semantic/keyword recall'); requireAll = $true }
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
$recentMemoryCount = 0
$recentMemoryOk = $false
$recentMemoryError = ''
try {
  $recentMemoryCountText = python -c "from sandglass_vault import recent; r=recent(3); print(len(r) if hasattr(r, '__len__') else 0)"
  if ($LASTEXITCODE -ne 0) { $ok = $false } else {
    $recentMemoryOk = $true
    $recentMemoryCount = [int](([string]$recentMemoryCountText).Trim())
  }
} catch {
  $recentMemoryError = $_.Exception.Message
  $ok = $false
}

$bindingPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'session-binding.json'
$sessionBinding = $null
if (Test-Path $bindingPath) {
  try {
    $binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $expired = $true
    try { $expired = ([datetime]::Parse([string]$binding.expiresAt) -lt (Get-Date)) } catch {}
    $sessionBinding = [pscustomObject]@{
      exists = $true
      active = ([string]$binding.status -eq 'active' -and -not $expired -and [string]$binding.packageVersion -eq [string](Get-SuperBrainManifest $Root).version -and (Test-SuperBrainSamePath ([string]$binding.memoryRoot) $MemoryRoot))
      status = $binding.status
      bindingId = $binding.bindingId
      sessionId = $binding.sessionId
      taskId = $binding.taskId
      expiresAt = $binding.expiresAt
      expired = $expired
      packageVersion = $binding.packageVersion
      packageVersionMatch = ([string]$binding.packageVersion -eq [string](Get-SuperBrainManifest $Root).version)
      memoryRootMatch = (Test-SuperBrainSamePath ([string]$binding.memoryRoot) $MemoryRoot)
      path = $bindingPath
    }
  } catch { $sessionBinding = [pscustomobject]@{ exists=$true; active=$false; status='parse_failed'; error=$_.Exception.Message; path=$bindingPath } }
} else { $sessionBinding = [pscustomobject]@{ exists=$false; active=$false; status='missing'; path=$bindingPath } }

if ($Json -or $DetailedJson) {
  if ($DetailedJson) {
    [pscustomobject]@{
      ok = $ok
      packageRoot = $Root
      memoryRoot = $MemoryRoot
      checks = $checks
      hookChecks = $hookChecks
      startupCheck = $startupCheck
      sessionBinding = $sessionBinding
      recentMemory = [pscustomobject]@{ ok=$recentMemoryOk; count=$recentMemoryCount; rawSuppressed=$true; error=$recentMemoryError }
    } | ConvertTo-Json -Depth 5
  } else {
    $failedChecks = @($checks | Where-Object { $_.ok -ne $true } | Select-Object -First 8 | ForEach-Object { [string]$_.name })
    $failedHookChecks = @($hookChecks | Where-Object { $_.ok -ne $true } | Select-Object -First 8 | ForEach-Object { [string]$_.name })
    [pscustomobject]@{
      ok = $ok
      packageRoot = $Root
      memoryRoot = $MemoryRoot
      checkCount = @($checks).Count
      failedCheckCount = $failedChecks.Count
      failedChecks = @($failedChecks)
      hookCheckCount = @($hookChecks).Count
      failedHookCheckCount = $failedHookChecks.Count
      failedHookChecks = @($failedHookChecks)
      startupOk = if ($startupCheck) { $startupCheck.ok } else { $null }
      sessionBinding = [pscustomobject]@{ exists=$sessionBinding.exists; active=$sessionBinding.active; status=$sessionBinding.status; path=$sessionBinding.path }
      recentMemory = [pscustomobject]@{ ok=$recentMemoryOk; count=$recentMemoryCount; rawSuppressed=$true; error=$recentMemoryError }
      detail = 'Use -DetailedJson for full checks.'
    } | ConvertTo-Json -Depth 5
  }
} else {
  foreach ($check in $checks) {
    if ($check.ok) { Write-Host "$($check.name): OK - $($check.path)" } else { Write-Host "$($check.name): MISSING - $($check.path)" }
  }
  foreach ($check in $hookChecks) {
    if ($check.ok) { Write-Host "$($check.name): OK" } else { Write-Host "$($check.name): MISSING" }
  }
  if ($startupCheck -and $startupCheck.ok -eq $true) { Write-Host 'Startup auto-check: OK' } else { Write-Host 'Startup auto-check: FAILED' }
  if ($sessionBinding.exists) { Write-Host "Session binding: status=$($sessionBinding.status) active=$($sessionBinding.active) expiresAt=$($sessionBinding.expiresAt) path=$($sessionBinding.path)" } else { Write-Host "Session binding: missing path=$($sessionBinding.path)" }
	  Write-Host "Recent memory: count=$recentMemoryCount rawSuppressed=True"
  if ($ok) { Write-Host 'STATUS_OK' } else { Write-Host 'STATUS_FAILED' }
}

if (-not $ok) { exit 1 }
exit 0