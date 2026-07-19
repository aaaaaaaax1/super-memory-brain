param(
  [string]$PackageRoot = "",
  [string]$HookPath = "",
  [int]$MaxStartupRuleChars = 320,
  [int]$MaxSessionLineChars = 900,
  [switch]$NoBackup
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
  $PackageRoot = Split-Path -Parent $PSScriptRoot
}
$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
$HookPath = Get-SuperBrainHookPath $HookPath

if (-not (Test-Path $HookPath)) {
  throw "Session-start hook not found: $HookPath"
}

$text = Get-Content -LiteralPath $HookPath -Raw -Encoding UTF8
$original = $text
$chineseSuperBrain = -join ([char[]](0x8D85,0x7EA7,0x5927,0x8111))
# Keep the verified semantic contract: visible G1 first/final; light recall if state needed.
$startupRule = "SuperBrain:explicit $chineseSuperBrain/Super Brain/G1/status/fault/start/refresh: load Skill super-memory-brain first; G1 first/final, mid plain; continue/previous/remember=recall; memory:auto silent; no G1 for ok/chat/code; ORC routes; Sandglass on semantic/keyword recall; Root:installed package-root.txt"
$startupLine = 'super_brain_content="' + $startupRule + '"'
$escapedLine = 'super_brain_escaped=$(escape_for_json "$super_brain_content")'
$sessionLine = 'session_context="<EXTREMELY_IMPORTANT>\nYou have superpowers.\n\n**Below is the full content of your ''superpowers:using-superpowers'' skill - your introduction to using skills. For all other skills, use the ''Skill'' tool:**\n\n${using_superpowers_escaped}\n\n<SUPER_MEMORY_BRAIN_STARTUP>\n${super_brain_escaped}\n</SUPER_MEMORY_BRAIN_STARTUP>\n\n${warning_escaped}\n</EXTREMELY_IMPORTANT>"'

if ($startupRule.Length -gt $MaxStartupRuleChars) {
  throw "Super Brain startup rule too long: $($startupRule.Length) > $MaxStartupRuleChars"
}
if ($sessionLine.Length -gt $MaxSessionLineChars) {
  throw "Session context line too long: $($sessionLine.Length) > $MaxSessionLineChars"
}

if ($text -match '(?m)^super_brain_content=') {
  $text = [regex]::Replace($text, '(?m)^super_brain_content=.*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $startupLine })
} else {
  $marker = 'warning_escaped=$(escape_for_json "$warning_message")'
  if (-not $text.Contains($marker)) { throw 'Session-start hook marker not found: warning_escaped' }
  $text = $text.Replace($marker, "$marker`n$startupLine`n$escapedLine")
}

if ($text -match '(?m)^super_brain_content=' -and $text -notmatch '(?m)^super_brain_escaped=') {
  $text = [regex]::Replace($text, '(?m)^super_brain_content=.*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "$($m.Value)`n$escapedLine" })
}

if ($text -match '(?m)^session_context=') {
  $text = [regex]::Replace($text, '(?m)^session_context=.*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $sessionLine })
} else {
  throw 'Session-start hook marker not found: session_context'
}

if ($text -ne $original) {
  if (-not $NoBackup) {
    $backup = "$HookPath.bak-super-memory-brain-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $HookPath -Destination $backup -Force
    Write-Host "Hook backup: $backup"
  }
  Write-Utf8NoBom $HookPath $text
  Write-Host "REPAIR_HOOK_UPDATED $HookPath"
} else {
  Write-Host "REPAIR_HOOK_NO_CHANGE $HookPath"
}

Write-Host "REPAIR_HOOK_OK package=$PackageRoot"
