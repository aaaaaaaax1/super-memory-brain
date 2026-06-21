param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$MemoryRoot = "",
  [string]$HookPath = "",
  [int]$MaxStartupRuleChars = 320,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) {
  $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
}
$HookPath = Get-SuperBrainHookPath $HookPath

$ok = $true
$checks = @()
$hookChecks = @()
$configChecks = @()

function Add-Check([string]$Name, [string]$Path) {
  $exists = Test-Path $Path
  if (-not $exists) { $script:ok = $false }
  $script:checks += [pscustomobject]@{ name=$Name; ok=$exists; path=$Path }
}

function Add-MarkerCheck([string]$Name, [object]$Result) {
  if (-not $Result.ok) { $script:ok = $false }
  $script:checks += [pscustomobject]@{ name=$Name; ok=$Result.ok; path=$Result.marker; actual=$Result.actual; expected=$Result.expected }
}

function Add-ConfigCheck([string]$Name, [string]$Path) {
  $exists = Test-Path $Path
  $script:configChecks += [pscustomobject]@{ name=$Name; ok=$exists; path=$Path }
}

function Add-HookCheck([string]$Name, [bool]$Found) {
  if (-not $Found) { $script:ok = $false }
  $script:hookChecks += [pscustomobject]@{ name=$Name; ok=$Found }
}

Add-Check 'ZCode super-memory-brain skill' (Join-Path $ZCodeSkills 'super-memory-brain\SKILL.md')
Add-Check 'ZCode skill-orchestrator skill' (Join-Path $ZCodeSkills 'skill-orchestrator\SKILL.md')
Add-Check 'ZCode plusunm-g1 skill' (Join-Path $ZCodeSkills 'plusunm-g1\SKILL.md')
Add-Check 'ZCode nexsandglass skill' (Join-Path $ZCodeSkills 'nexsandglass-dedicated-memory\SKILL.md')
Add-Check 'Codex super-memory-brain skill' (Join-Path $CodexSkills 'super-memory-brain\SKILL.md')
Add-Check 'Codex skill-orchestrator skill' (Join-Path $CodexSkills 'skill-orchestrator\SKILL.md')
Add-Check 'Codex plusunm-g1 skill' (Join-Path $CodexSkills 'plusunm-g1\SKILL.md')
Add-Check 'Codex nexsandglass skill' (Join-Path $CodexSkills 'nexsandglass-dedicated-memory\SKILL.md')
Add-Check 'Package memory root' $MemoryRoot
Add-Check 'Session-start hook' $HookPath

foreach ($skillName in Get-SuperBrainSkillNames) {
  Add-MarkerCheck "ZCode $skillName package root" (Test-SuperBrainPackageRootMarker (Join-Path $ZCodeSkills $skillName) $Root)
  Add-MarkerCheck "ZCode $skillName memory root" (Test-SuperBrainMemoryRootMarker (Join-Path $ZCodeSkills $skillName))
  Add-MarkerCheck "Codex $skillName package root" (Test-SuperBrainPackageRootMarker (Join-Path $CodexSkills $skillName) $Root)
  Add-MarkerCheck "Codex $skillName memory root" (Test-SuperBrainMemoryRootMarker (Join-Path $CodexSkills $skillName))
}

Add-ConfigCheck 'ZCode CLI config' "$env:USERPROFILE\.zcode\cli\config.json"
Add-ConfigCheck 'ZCode v2 settings' "$env:USERPROFILE\.zcode\v2\setting.json"
Add-ConfigCheck 'ZCode v2 config' "$env:USERPROFILE\.zcode\v2\config.json"
Add-ConfigCheck 'Codex config' "$env:USERPROFILE\.codex\config.toml"

if (Test-Path $HookPath) {
  $hookText = Get-Content -LiteralPath $HookPath -Raw -Encoding UTF8
  $escapedRoot = $Root.Replace('\', '\\')
  Add-HookCheck 'Hook default startup rule' (($hookText -like '*SuperBrain:*') -or ($hookText -like '*Super Brain default:*') -or ($hookText -like '*Default Super Brain startup rule*'))
  Add-HookCheck 'Hook entry skill' ($hookText -like '*super-memory-brain*')
  $chineseSuperBrain = -join ([char[]](0x8D85,0x7EA7,0x5927,0x8111))
  Add-HookCheck 'Hook mandatory skill load' (($hookText -like '*load super-memory-brain for recall/status*') -or ($hookText -like '*load super-memory-brain for Super Brain*') -or ($hookText -like '*load Skill super-memory-brain first*') -or ($hookText -like '*Load Skill super-memory-brain first*'))
  Add-HookCheck 'Hook bare Super Brain wake words' (($hookText -like '*bare*') -and ($hookText -like "*$chineseSuperBrain*") -and ($hookText -like '*Super Brain*') -and ($hookText -like '*G1*') -and ($hookText -like '*load Skill super-memory-brain first*'))
  Add-HookCheck 'Hook explicit Super Brain triggers' (($hookText -like '*Super Brain*') -and ($hookText -like '*G1*') -and (($hookText -like '*enable/start/refresh*') -or ($hookText -like '*optimize/start/refresh*')))
  Add-HookCheck 'Hook memory policy' (($hookText -like '*memory:auto*') -or ($hookText -like '*stable state only*') -or ($hookText -like '*Memory shortcut:*'))
  Add-HookCheck 'Hook recall trigger' (($hookText -like '*semantic/keyword recall*') -or ($hookText -like '*state/version/progress/remember/previous-session*') -or ($hookText -like '*Recall previous*') -or ($hookText -like '*Recall trigger:*'))
  Add-HookCheck 'Hook on-demand checks' (($hookText -like '*Checks on demand*') -or ($hookText -like '*Checks are on demand*') -or ($hookText -like '*Startup auto-check:*'))
  Add-HookCheck 'Hook short router' (($hookText -like '*G1 governs*') -and ($hookText -like '*ORC routes*') -and ($hookText -like '*Sandglass only on semantic/keyword recall*'))
  Add-HookCheck 'Hook current package path' (($hookText -like "*$Root*") -or ($hookText -like "*$escapedRoot*"))

  $startupRuleMatch = [regex]::Match($hookText, '(?m)^super_brain_content="(?<rule>.*)"$')
  $startupRuleLengthOk = $false
  if ($startupRuleMatch.Success) { $startupRuleLengthOk = $startupRuleMatch.Groups['rule'].Value.Length -le $MaxStartupRuleChars }
  Add-HookCheck 'Hook startup rule length' $startupRuleLengthOk
}

if ($Json) {
  [pscustomobject]@{ ok=$ok; packageRoot=$Root; memoryRoot=$MemoryRoot; hookPath=$HookPath; checks=$checks; hookChecks=$hookChecks; configChecks=$configChecks } | ConvertTo-Json -Depth 6
} else {
  foreach ($check in $checks) { if ($check.ok) { Write-Host "OK $($check.name) - $($check.path)" } else { Write-Host "MISSING $($check.name) - $($check.path) actual=$($check.actual) expected=$($check.expected)" } }
  foreach ($check in $hookChecks) { if ($check.ok) { Write-Host "OK $($check.name)" } else { Write-Host "MISSING $($check.name)" } }
  foreach ($check in $configChecks) { if ($check.ok) { Write-Host "OK $($check.name) - $($check.path)" } else { Write-Host "MISSING $($check.name) - $($check.path)" } }
  if ($ok) { Write-Host 'STARTUP_CHECK_OK' } else { Write-Host 'STARTUP_CHECK_FAILED' }
}

if (-not $ok) { exit 1 }
exit 0
