param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statusPath = Join-Path $workspace 'last-host-cache-check.json'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function File-HashShort([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.Substring(0, 12) } catch { return '' }
}
function Read-Text([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim() } catch { return '' }
}
function Get-SkillVersion([string]$Path) {
  $text = Read-Text $Path
  if ([string]::IsNullOrWhiteSpace($text)) { return '' }
  $match = [regex]::Match($text, 'Package Version:\s*([0-9]+\.[0-9]+\.[0-9]+)')
  if ($match.Success) { return $match.Groups[1].Value }
  $match = [regex]::Match($text, '##\s+([0-9]+\.[0-9]+\.[0-9]+)')
  if ($match.Success) { return $match.Groups[1].Value }
  return ''
}
function New-HostResult([string]$Name, [string]$SkillPath, [string]$PackageRootMarker, [string]$MemoryRootMarker) {
  $sourceSkill = Join-Path $Root 'super-memory-brain\SKILL.md'
  $sourceHash = File-HashShort $sourceSkill
  $skillHash = File-HashShort $SkillPath
  $packageRoot = Read-Text $PackageRootMarker
  $memoryRoot = Read-Text $MemoryRootMarker
  $exists = Test-Path -LiteralPath $SkillPath
  $contentMatches = ($exists -and $sourceHash -ne '' -and $sourceHash -eq $skillHash)
  $packageRootMatches = ($packageRoot -eq $Root)
  $version = Get-SkillVersion $SkillPath
  return [pscustomobject]@{
    host = $Name
    skillPath = $SkillPath
    exists = $exists
    version = $version
    expectedVersion = [string]$manifest.version
    hash = $skillHash
    sourceHash = $sourceHash
    contentMatches = $contentMatches
    packageRootMarker = $PackageRootMarker
    packageRoot = $packageRoot
    packageRootMatches = $packageRootMatches
    memoryRootMarker = $MemoryRootMarker
    memoryRoot = $memoryRoot
    markerOk = ($packageRootMatches -and -not [string]::IsNullOrWhiteSpace($memoryRoot))
    installedFresh = ($exists -and $contentMatches -and $packageRootMatches)
  }
}

$userHome = [Environment]::GetFolderPath('UserProfile')
$hosts = @()
$hosts += New-HostResult 'zcode' (Join-Path $userHome '.zcode\skills\super-memory-brain\SKILL.md') (Join-Path $userHome '.zcode\skills\super-memory-brain\package-root.txt') (Join-Path $userHome '.zcode\skills\super-memory-brain\memory-root.txt')
$hosts += New-HostResult 'codex' (Join-Path $userHome '.codex\skills\super-memory-brain\SKILL.md') (Join-Path $userHome '.codex\skills\super-memory-brain\package-root.txt') (Join-Path $userHome '.codex\skills\super-memory-brain\memory-root.txt')
$staleHosts = @($hosts | Where-Object { $_.installedFresh -ne $true })
$lastHotRefresh = $null
$hotRefreshPath = Join-Path $workspace 'last-hot-refresh.json'
if (Test-Path -LiteralPath $hotRefreshPath) { try { $lastHotRefresh = Get-Content -LiteralPath $hotRefreshPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }

$result = [pscustomobject]@{
  ok = ($staleHosts.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = [string]$manifest.version
  packageRoot = $Root
  hosts = @($hosts)
  staleHosts = @($staleHosts | ForEach-Object { $_.host })
  lastHotRefresh = if ($lastHotRefresh) { [pscustomobject]@{ ok=$lastHotRefresh.ok; checkedAt=$lastHotRefresh.checkedAt; version=$lastHotRefresh.version } } else { $null }
  currentSessionCacheRisk = 'unknown_to_script'
  loadedSkillLimitation = 'Host scripts can verify installed files and markers, but cannot inspect the skill text already loaded into this chat context.'
  newSessionPrompt = 'Open a new ZCode/Codex session and invoke Super Brain if behavior still looks stale.'
  note = 'This checks installed skill files and markers. It cannot inspect the already-loaded skill text inside the current chat session; if installed files changed after this session loaded the skill, open a new session.'
  recommendedAction = if ($staleHosts.Count -gt 0) { 'Run hot-refresh-skills.ps1 -AllKnown, then open a new session if the host cached old skill content.' } else { 'Installed skill copies are fresh. Open a new session only if this chat loaded old skill text before refresh.' }
  statusPath = $statusPath
}
Write-JsonUtf8NoBom $statusPath $result 12
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "HOST_CACHE_CHECK ok=$($result.ok) stale=$($staleHosts.Count) status=$statusPath" }
if (-not $result.ok) { exit 1 }
exit 0
