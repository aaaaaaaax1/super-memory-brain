param(
  [switch]$Fix
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$targets = @(
  'CURRENT_BASELINE.md',
  'BASELINE_HISTORY.md',
  'CHANGELOG.md',
  'README.md',
  'super-memory-brain\SKILL.md',
  'super-brain-rules.json',
  'route-map.json',
  'manifest.json',
  'scripts\common.ps1',
  'scripts\bootstrap.ps1',
  'scripts\install.ps1',
  'scripts\install-runtime.ps1',
  'scripts\first-load-bootstrap.ps1',
  'scripts\startup-check.ps1',
  'scripts\status.ps1',
  'scripts\health-check.ps1',
  'scripts\hot-refresh-skills.ps1',
  'scripts\skill-sync-check.ps1',
  'runtime\brain_mcp.py',
  'README.md',
  'START_HERE.md',
  'super-brain-rules.json'
)

$badProject = 'Zcode' + [string][char]0x6924 + [string][char]0x572D + [string][char]0x6D30
$goodProject = 'Zcode' + [string][char]0x9879 + [string][char]0x76EE
$patterns = @(
  [string][char]0x9239,
  [string][char]0x951B,
  [string][char]0x7039,
  $badProject,
  [string][char]0xFFFD
)
$ok = $true

foreach ($rel in $targets) {
  $path = Join-Path $Root $rel
  if (-not (Test-Path $path)) { continue }
  $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  $hits = @()
  foreach ($pattern in $patterns) {
    if ($text.Contains($pattern)) { $hits += ('U+' + ([int][char]$pattern[0]).ToString('X4')) }
  }
  if ($hits.Count -eq 0) {
    Write-Host "OK encoding $rel"
    continue
  }

  $ok = $false
  Write-Host "FOUND mojibake $rel patterns=$($hits -join ',')"
  if ($Fix) {
    $fixed = $text.Replace($badProject, $goodProject)
    if ($fixed -ne $text) {
      [IO.File]::WriteAllText($path, $fixed, [Text.UTF8Encoding]::new($false))
      Write-Host "FIXED encoding $rel"
    }
  }
}

if ($Fix) {
  Write-Host 'ENCODING_CHECK_FIX_DONE'
  exit 0
}

if ($ok) {
  Write-Host 'ENCODING_CHECK_OK'
  exit 0
}

Write-Host 'ENCODING_CHECK_FOUND_ISSUES'
exit 1
