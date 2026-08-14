param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$mergeOverlay = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'merge-overlay'
$uiEventLog = Join-Path $workspace 'last-install-ui-events.log'

function New-PathCheck([string]$Name, [string]$Path, [bool]$Required, [string[]]$RequiredChildren = @()) {
  $exists = Test-Path $Path
  $childrenOk = $true
  $missingChildren = @()
  if ($exists) {
    foreach ($child in $RequiredChildren) {
      if (-not (Test-Path (Join-Path $Path $child))) {
        $childrenOk = $false
        $missingChildren += $child
      }
    }
  }
  $ok = if ($Required) { $exists -and $childrenOk } else { $true }
  return [pscustomobject]@{
    name = $Name
    path = $Path
    required = $Required
    exists = $exists
    childrenOk = $childrenOk
    missingChildren = @($missingChildren)
    ok = $ok
  }
}

function New-AgentSkillCandidate([string]$Name, [string]$Path, [string]$Reason) {
  $expanded = [Environment]::ExpandEnvironmentVariables($Path)
  try { $full = [System.IO.Path]::GetFullPath($expanded) } catch { $full = $expanded }
  return [pscustomobject]@{
    name = Get-SafeSuperBrainName $Name 'agent'
    path = $full
    exists = (Test-Path $full)
    reason = $Reason
  }
}

function Test-LegacyBrainUiCompatibility {
  $missing = @()
  $brainUiPath = Join-Path $PSScriptRoot 'brain-ui.vbs'
  $installUiVbsPath = Join-Path $PSScriptRoot 'install-ui.vbs'
  $controlCenterPath = Join-Path $PSScriptRoot 'open-control-center.ps1'
  $controlCenterServerPath = Join-Path $Root 'runtime\brain_ui_server.py'
  $controlCenterIndexPath = Join-Path $Root 'ui\dist\index.html'
  if (-not (Test-Path -LiteralPath $brainUiPath)) {
    return [pscustomobject]@{ ok = $false; missing = @('brain-ui.vbs') }
  }
  if (-not (Test-Path -LiteralPath $installUiVbsPath)) {
    return [pscustomobject]@{ ok = $false; missing = @('install-ui.vbs') }
  }

  $brainUiText = [System.IO.File]::ReadAllText($brainUiPath, [System.Text.Encoding]::UTF8)
  $installUiVbsText = [System.IO.File]::ReadAllText($installUiVbsPath, [System.Text.Encoding]::UTF8)
  foreach ($token in @('CONTROL_CENTER_LAUNCHER', 'open-control-center.ps1', 'brain_ui_server.py', 'ui\dist\index.html', 'did not fall back')) {
    if (-not $brainUiText.Contains($token)) { $missing += "brain-ui.vbs marker $token" }
  }
  foreach ($pathCheck in @($controlCenterPath, $controlCenterServerPath, $controlCenterIndexPath)) {
    if (-not (Test-Path -LiteralPath $pathCheck -PathType Leaf)) { $missing += "control center path $pathCheck" }
  }
  foreach ($token in @('Option Explicit', 'install-ui.ps1', 'WScript.Quit exitCode')) {
    if (-not $installUiVbsText.Contains($token)) { $missing += "install-ui.vbs marker $token" }
  }

  $obsoletePatterns = @(
    '(?im)^\s*installer\s*=.*windows_install\.ps1',
    '(?im)^\s*appModule\s*=.*brain_console_app\.py',
    '(?im)^\s*appScript\s*=.*brain_console\.py',
    '(?im)^\s*rc\s*=.*run_brain_console\.ps1'
  )
  foreach ($pattern in $obsoletePatterns) {
    if ([regex]::IsMatch($brainUiText, $pattern)) { $missing += "brain-ui.vbs active legacy reference $pattern" }
  }
  return [pscustomobject]@{ ok = ($missing.Count -eq 0); missing = @($missing) }
}

$requiredScripts = @(
  'bootstrap.ps1',
  'install.ps1',
  'install-agent.ps1',
  'install-ui.ps1',
  'install-ui.vbs',
  'brain-ui.vbs',
  'open-control-center.ps1',
  'hot-refresh-skills.ps1',
  'migrate-memory-layout.ps1',
  'cleanup-install-backups.ps1',
  'health-summary.ps1',
  'smart-next.ps1'
)

$pathChecks = @(
  (New-PathCheck 'package root' $Root $true @('manifest.json','scripts','super-memory-brain','modules','memory')),
  (New-PathCheck 'scripts root' $PSScriptRoot $true @($requiredScripts)),
  (New-PathCheck 'control center assets' (Join-Path $Root 'ui\dist') $true @('index.html','assets\app.js','assets\app.css','vendor\react.production.min.js','vendor\react-dom.production.min.js')),
  (New-PathCheck 'workspace root' $workspace $true @()),
  (New-PathCheck 'memory root' (Get-SuperBrainMemoryBaseRoot $Root) $true @('shared')),
  (New-PathCheck 'shared memory root' (Get-SuperBrainSharedMemoryRoot $Root) $true @('sandglass.txt')),
  (New-PathCheck 'public memory runtime source' (Get-SuperBrainRuntimeSourceRoot $Root) $true @('sandglass_vault.py','sandglass_log.py')),
  (New-PathCheck 'merge overlay import folder' $mergeOverlay $false @()),
  (New-PathCheck 'last UI event log' $uiEventLog $false @())
)

$scriptChecks = @($requiredScripts | ForEach-Object {
  $path = Join-Path $PSScriptRoot $_
  [pscustomobject]@{ name = $_; path = $path; exists = (Test-Path $path); ok = (Test-Path $path) }
})
$legacyBrainUiCompatibility = Test-LegacyBrainUiCompatibility

$agentCandidates = @(
  (New-AgentSkillCandidate 'zcode' "$env:USERPROFILE\.zcode\skills" 'known ZCode skills root'),
  (New-AgentSkillCandidate 'codex' "$env:USERPROFILE\.codex\skills" 'known Codex skills root'),
  (New-AgentSkillCandidate 'claude' "$env:USERPROFILE\.claude\skills" 'common Claude Code skills root'),
  (New-AgentSkillCandidate 'cursor' "$env:USERPROFILE\.cursor\skills" 'common Cursor skills root'),
  (New-AgentSkillCandidate 'windsurf' "$env:USERPROFILE\.windsurf\skills" 'common Windsurf skills root'),
  (New-AgentSkillCandidate 'roo' "$env:USERPROFILE\.roo\skills" 'common Roo Code skills root'),
  (New-AgentSkillCandidate 'cline' "$env:USERPROFILE\.cline\skills" 'common Cline skills root'),
  (New-AgentSkillCandidate 'continue' "$env:USERPROFILE\.continue\skills" 'common Continue skills root'),
  (New-AgentSkillCandidate 'gemini' "$env:USERPROFILE\.gemini\skills" 'common Gemini CLI skills root'),
  (New-AgentSkillCandidate 'opencode' "$env:USERPROFILE\.opencode\skills" 'common OpenCode skills root'),
  (New-AgentSkillCandidate 'aider' "$env:USERPROFILE\.aider\skills" 'common Aider skills root')
)

$ok = (@($pathChecks | Where-Object { $_.ok -ne $true }).Count -eq 0) -and (@($scriptChecks | Where-Object { $_.ok -ne $true }).Count -eq 0) -and $legacyBrainUiCompatibility.ok
$result = [pscustomobject]@{
  ok = $ok
  packageRoot = $Root
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  requiredScripts = @($scriptChecks)
  paths = @($pathChecks)
  legacyBrainUiCompatibility = $legacyBrainUiCompatibility
  agentCandidates = @($agentCandidates)
  existingAgentCandidateCount = @($agentCandidates | Where-Object { $_.exists }).Count
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
} else {
  Write-Host "INSTALL_UI_PATHS ok=$($result.ok) package=$Root existingAgents=$($result.existingAgentCandidateCount)"
  foreach ($check in @($result.paths)) {
    $status = if ($check.ok) { 'OK' } else { 'FAILED' }
    Write-Host "$status path name=$($check.name) required=$($check.required) exists=$($check.exists) $($check.path)"
  }
  foreach ($check in @($result.requiredScripts)) {
    $status = if ($check.ok) { 'OK' } else { 'FAILED' }
    Write-Host "$status script $($check.name)"
  }
  $compatibilityStatus = if ($result.legacyBrainUiCompatibility.ok) { 'OK' } else { 'FAILED' }
  Write-Host "$compatibilityStatus legacy brain UI compatibility missing=$($result.legacyBrainUiCompatibility.missing -join ',')"
}

if (-not $ok) { exit 1 }
exit 0
