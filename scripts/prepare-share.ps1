param(
  [string]$Destination = "",
  [switch]$Force
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$MarkerName = '.super-memory-brain-share-marker'

function Get-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathSameOrInside([string]$Child, [string]$Parent) {
  $childFull = Get-FullPath $Child
  $parentFull = Get-FullPath $Parent
  return ($childFull -eq $parentFull -or $childFull.StartsWith($parentFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-LegacyDefaultShareDestination([string]$Path) {
  $destFull = Get-FullPath $Path
  $parentFull = Get-FullPath (Split-Path -Parent $Root)
  $name = Split-Path -Leaf $destFull
  return ((Get-FullPath (Split-Path -Parent $destFull)) -eq $parentFull -and $name -like 'super-memory-brain-package-share*')
}

function Assert-SafeDestination([string]$Path) {
  $destFull = Get-FullPath $Path
  $rootFull = Get-FullPath $Root
  $parentFull = Get-FullPath (Split-Path -Parent $Root)
  $homeFull = if ($env:USERPROFILE) { Get-FullPath $env:USERPROFILE } else { '' }
  $driveRoot = [System.IO.Path]::GetPathRoot($destFull).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

  if ($destFull -eq $rootFull) { throw "Unsafe share destination equals package root: $destFull" }
  if ($destFull -eq $parentFull) { throw "Unsafe share destination equals package parent: $destFull" }
  if ($homeFull -and $destFull -eq $homeFull) { throw "Unsafe share destination equals user profile: $destFull" }
  if ($destFull.TrimEnd('\','/') -eq $driveRoot) { throw "Unsafe share destination equals drive root: $destFull" }
  if (Test-PathSameOrInside $Root $destFull) { throw "Unsafe share destination contains package root: $destFull" }
}

function Write-PublicGitIgnore([string]$Path) {
  $content = @'
# Super Memory Brain public release guardrails
# This share package is intended for GitHub/public distribution.
# Keep local memory, machine-specific state, caches, logs, and secrets out of git.

# Local memory and state
memory/shared/**
memory/agents/**
memory/groups/**
memory/workspace/**
memory/persona/**
memory/archive/**
memory/**/*.db
memory/**/*.idx
memory/**/*.bak*
memory/**/sandglass.txt
memory/**/decision_particles.txt
memory/**/shadow_sand.db
memory/**/metrics.jsonl
memory/**/search_weights.txt

# Local install markers and sharing policy
package-root.txt
memory-root.txt
.memory-scope.json
memory-sharing-policy.json

# Generated caches
__pycache__/
*.pyc

# Backups and generated releases
install-backup-*/
super-memory-brain-package-share*/
super-memory-brain-package-private*/
super-memory-brain-package-release-v*/

# Secrets and key material
.env
*.env
*.secret
*.key
*.pem
*.pfx

# Logs and local status snapshots
*.log
memory/workspace/last-*.json
memory/workspace/last-*.log
'@
  Write-Utf8NoBom (Join-Path $Path '.gitignore') ($content.TrimStart("`r", "`n") + "`n")
}

function ConvertTo-PublicText([string]$Text) {
  $memoryBase = Get-SuperBrainMemoryBaseRoot $Root
  $replacements = @(
    @{ From = $Root; To = '<package-root>' },
    @{ From = $memoryBase; To = '<memory-root>' },
    @{ From = $env:USERPROFILE; To = '<user-home>' },
    @{ From = '<user-home>'; To = '<user-home>' },
    @{ From = 'G:\Ai\Zcode项目'; To = '<workspace-root>' }
  )
  $result = $Text
  foreach ($replacement in $replacements) {
    if (-not [string]::IsNullOrWhiteSpace($replacement.From)) {
      $result = $result.Replace($replacement.From, $replacement.To)
    }
  }
  return $result
}

function Convert-PublicTextFiles([string]$Path) {
  $extensions = @('.md','.json','.ps1','.bat','.py','.txt','.toml','.yaml','.yml')
  foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $extensions -contains $_.Extension })) {
    try {
      $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
      $publicText = ConvertTo-PublicText $text
      if ($publicText -ne $text) {
        Write-Utf8NoBom $file.FullName $publicText
      }
    } catch {}
  }
}

if ([string]::IsNullOrWhiteSpace($Destination)) {
  $Destination = Join-Path (Split-Path -Parent $Root) 'super-memory-brain-package-share'
}

$Destination = Get-FullPath $Destination
Assert-SafeDestination $Destination

if (Test-Path $Destination) {
  $markerPath = Join-Path $Destination $MarkerName
  $legacyDefaultShare = Test-LegacyDefaultShareDestination $Destination
  if (-not (Test-Path $markerPath) -and -not $legacyDefaultShare -and -not $Force) {
    throw "Destination exists and is not marked as a Super Memory Brain share package. Use -Force only after checking it: $Destination"
  }
  Remove-Item -LiteralPath $Destination -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
Write-Utf8NoBom (Join-Path $Destination $MarkerName) "super-memory-brain-share`nsource=<package-root>`ncreated=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$manifest = Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$items = @('README.md','QUICK_START.md','COMMANDS.md','manifest.json','CHANGELOG.md','CURRENT_BASELINE.md','BASELINE_HISTORY.md','memory-policy.json','super-memory-brain','modules','tests')
foreach ($item in $items) {
  $src = Join-Path $Root $item
  if (Test-Path $src) {
    Copy-Item -LiteralPath $src -Destination (Join-Path $Destination $item) -Recurse -Force
  }
}

$scriptDest = Join-Path $Destination 'scripts'
New-Item -ItemType Directory -Force -Path $scriptDest | Out-Null
foreach ($script in $manifest.scripts) {
  $src = Join-Path (Join-Path $Root 'scripts') $script
  if (-not (Test-Path $src)) { throw "Manifest script missing: $script" }
  Copy-Item -LiteralPath $src -Destination (Join-Path $scriptDest $script) -Force
}

$mem = Join-Path $Destination 'memory'
New-Item -ItemType Directory -Force -Path (Join-Path $mem 'scripts'),(Join-Path $mem 'persona'),(Join-Path $mem 'archive'),(Join-Path $mem 'shared'),(Join-Path $mem 'agents'),(Join-Path $mem 'groups') | Out-Null

$vendorSource = Join-Path $Root 'vendor\NexSandglass-Agent-DedicatedMemory'
$vendorDest = Join-Path $Destination 'vendor\NexSandglass-Agent-DedicatedMemory'
$runtime = Join-Path $mem 'scripts'
New-Item -ItemType Directory -Force -Path $vendorDest | Out-Null

$files = Get-SuperBrainRuntimeFiles $Root
foreach ($f in $files) {
  $src = Join-Path $vendorSource $f
  if (Test-Path $src) {
    Copy-Item -LiteralPath $src -Destination (Join-Path $runtime $f) -Force
    Copy-Item -LiteralPath $src -Destination (Join-Path $vendorDest $f) -Force
  }
}

$docPatterns = @('README*','LICENSE*','NOTICE*')
foreach ($pattern in $docPatterns) {
  foreach ($doc in @(Get-ChildItem -LiteralPath $vendorSource -File -Filter $pattern -ErrorAction SilentlyContinue)) {
    Copy-Item -LiteralPath $doc.FullName -Destination (Join-Path $vendorDest $doc.Name) -Force
  }
}

Convert-PublicTextFiles $Destination
Write-PublicGitIgnore $Destination

Write-Host "SHARE_PACKAGE_CREATED $Destination"
Write-Host 'Private memory files were not copied: sandglass.txt, sandglass.idx, sandglass.db, shadow_sand.db, decision_particles.txt, workspace state, persona data, archive data.'
Write-Host 'Share destination is protected: existing unmarked directories require explicit -Force.'
Write-Host 'Share package slimmed: scripts are manifest-driven; vendor excludes .git, zip, demo, cache, and private/generated files.'
Write-Host 'GitHub guardrails added: root .gitignore excludes local memory, markers, caches, logs, releases, and secrets.'
