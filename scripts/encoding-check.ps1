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
  'memory\sandglass.txt',
  'memory\graph.jsonl',
  'memory\workspace\session-notes.md'
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
      Set-Content -LiteralPath $path -Value $fixed -Encoding UTF8
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
