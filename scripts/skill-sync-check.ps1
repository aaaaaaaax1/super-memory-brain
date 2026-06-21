param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$items = @(
  @{ name='super-memory-brain'; source='super-memory-brain\SKILL.md' },
  @{ name='skill-orchestrator'; source='modules\skill-orchestrator\SKILL.md' },
  @{ name='plusunm-g1'; source='modules\plusunm-g1\SKILL.md' },
  @{ name='nexsandglass-dedicated-memory'; source='modules\nexsandglass-dedicated-memory\SKILL.md' }
)
$ok = $true
$results = @()

function Hash-File([string]$Path) {
  if (-not (Test-Path $Path)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

foreach ($item in $items) {
  $src = Join-Path $Root $item.source
  $zDir = Join-Path $ZCodeSkills $item.name
  $cDir = Join-Path $CodexSkills $item.name
  $z = Join-Path $zDir 'SKILL.md'
  $c = Join-Path $cDir 'SKILL.md'
  $srcHash = Hash-File $src
  $zHash = Hash-File $z
  $cHash = Hash-File $c
  $zOk = ($srcHash -ne $null -and $srcHash -eq $zHash)
  $cOk = ($srcHash -ne $null -and $srcHash -eq $cHash)
  $zPackageRoot = Test-SuperBrainPackageRootMarker $zDir $Root
  $cPackageRoot = Test-SuperBrainPackageRootMarker $cDir $Root
  $zMemoryRoot = Test-SuperBrainMemoryRootMarker $zDir
  $cMemoryRoot = Test-SuperBrainMemoryRootMarker $cDir
  if (-not ($zOk -and $cOk -and $zPackageRoot.ok -and $cPackageRoot.ok -and $zMemoryRoot.ok -and $cMemoryRoot.ok)) { $ok = $false }
  $results += [pscustomobject]@{
    name = $item.name
    zcodeOk = $zOk
    codexOk = $cOk
    zcodePackageRootOk = $zPackageRoot.ok
    codexPackageRootOk = $cPackageRoot.ok
    zcodeMemoryRootOk = $zMemoryRoot.ok
    codexMemoryRootOk = $cMemoryRoot.ok
    source = $src
    zcode = $z
    codex = $c
    zcodePackageRoot = $zPackageRoot
    codexPackageRoot = $cPackageRoot
    zcodeMemoryRoot = $zMemoryRoot
    codexMemoryRoot = $cMemoryRoot
  }
}

if ($Json) {
  [pscustomobject]@{ ok=$ok; packageRoot=(Get-NormalizedSuperBrainRoot $Root); results=$results } | ConvertTo-Json -Depth 8
} else {
  foreach ($r in $results) {
    Write-Host "SKILL_SYNC $($r.name) zcode=$($r.zcodeOk) codex=$($r.codexOk) zcodePackageRoot=$($r.zcodePackageRootOk) codexPackageRoot=$($r.codexPackageRootOk) zcodeMemoryRoot=$($r.zcodeMemoryRootOk) codexMemoryRoot=$($r.codexMemoryRootOk)"
  }
  if ($ok) { Write-Host 'SKILL_SYNC_OK' } else { Write-Host 'SKILL_SYNC_FAILED' }
}

if (-not $ok) { exit 1 }
exit 0
