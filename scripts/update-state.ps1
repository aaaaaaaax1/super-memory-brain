param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$MemoryRoot = "",
  [switch]$AllowStaleVerify,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) {
  $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
}
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$statePath = Join-Path $workspace 'super-brain-state.json'

$manifest = Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$startup = $null
try {
  $startupText = & (Join-Path $PSScriptRoot 'startup-check.ps1') -ZCodeSkills $ZCodeSkills -CodexSkills $CodexSkills -MemoryRoot $MemoryRoot -Json
  $startup = $startupText | ConvertFrom-Json
} catch {
  $startup = [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
}

$lastVerifyPath = Join-Path $workspace 'last-verify-package.json'
$lastVerifyOk = $false
$lastVerifyAt = $null
if (Test-Path $lastVerifyPath) {
  try {
    $lastVerify = Get-Content -LiteralPath $lastVerifyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lastVerifyOk = ($lastVerify.ok -eq $true)
    $lastVerifyAt = $lastVerify.checkedAt
  } catch {}
}

$state = [pscustomobject]@{
  ok = (($startup.ok -eq $true) -and (($lastVerifyOk -eq $true) -or ($AllowStaleVerify -eq $true)))
  version = $manifest.version
  packageRoot = $Root
  memoryRoot = $MemoryRoot
  hookOk = ($startup.ok -eq $true)
  lastVerifyOk = $lastVerifyOk
  lastVerifyAt = $lastVerifyAt
  updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}
Write-JsonUtf8NoBom $statePath $state 5

if ($Json) {
  Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
} else {
  Write-Host "STATE_UPDATE_OK $statePath version=$($state.version) hookOk=$($state.hookOk)"
}

if (-not $state.ok) { exit 1 }
exit 0
