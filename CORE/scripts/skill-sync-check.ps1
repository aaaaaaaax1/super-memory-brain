param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [switch]$IncludeZCode,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$zcodeHostPresent = $IncludeZCode -and ((Test-Path -LiteralPath (Split-Path -Parent ([IO.Path]::GetFullPath($ZCodeSkills)))) -or (Test-Path -LiteralPath $ZCodeSkills))
$codexHostPresent = (Test-Path -LiteralPath (Split-Path -Parent ([IO.Path]::GetFullPath($CodexSkills)))) -or (Test-Path -LiteralPath $CodexSkills)
# Only the public Super Brain adapter is a host-install requirement. The
# remaining modules are package-owned cold/internal capabilities.
$items = @(
  @{ name='super-memory-brain'; source='super-memory-brain\SKILL.md'; hostInstallPolicy='required' }
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
  $absorbed = ([string]$item.hostInstallPolicy -eq 'absorbed_package_capability_source')
  $zPresent = Test-Path -LiteralPath $zDir -PathType Container
  $cPresent = Test-Path -LiteralPath $cDir -PathType Container
  if ($absorbed) {
    # Absorbed sources are healthy only when they are not visible as host
    # skills. Their package files remain available through Super Brain routing.
    $zOk = -not $zPresent
    $cOk = -not $cPresent
  } else {
    $zOk = (-not $zcodeHostPresent) -or ($srcHash -ne $null -and $srcHash -eq $zHash)
    $cOk = (-not $codexHostPresent) -or ($srcHash -ne $null -and $srcHash -eq $cHash)
  }
  $zPackageRoot = Test-SuperBrainPackageRootMarker $zDir $Root
  $cPackageRoot = Test-SuperBrainPackageRootMarker $cDir $Root
  $zMemoryRoot = Test-SuperBrainMemoryRootMarker $zDir
  $cMemoryRoot = Test-SuperBrainMemoryRootMarker $cDir
  if ($absorbed) {
    $zPackageRootOk = -not $zPresent
    $cPackageRootOk = -not $cPresent
    $zMemoryRootOk = -not $zPresent
    $cMemoryRootOk = -not $cPresent
  } else {
    $zPackageRootOk = (-not $zcodeHostPresent) -or [bool]$zPackageRoot.ok
    $cPackageRootOk = (-not $codexHostPresent) -or [bool]$cPackageRoot.ok
    $zMemoryRootOk = (-not $zcodeHostPresent) -or [bool]$zMemoryRoot.ok
    $cMemoryRootOk = (-not $codexHostPresent) -or [bool]$cMemoryRoot.ok
  }
  if (-not ($zOk -and $cOk -and $zPackageRootOk -and $cPackageRootOk -and $zMemoryRootOk -and $cMemoryRootOk)) { $ok = $false }
  $results += [pscustomobject]@{
    name = $item.name
    zcodeOk = $zOk
    codexOk = $cOk
    includeZCode = [bool]$IncludeZCode
    zcodeHostPresent = $zcodeHostPresent
    codexHostPresent = $codexHostPresent
    zcodeSkipped = (-not $IncludeZCode) -or (-not $zcodeHostPresent)
    codexSkipped = (-not $codexHostPresent)
    hostInstallPolicy = [string]$item.hostInstallPolicy
    absorbed = $absorbed
    zcodePresent = $zPresent
    codexPresent = $cPresent
    zcodePackageRootOk = $zPackageRootOk
    codexPackageRootOk = $cPackageRootOk
    zcodeMemoryRootOk = $zMemoryRootOk
    codexMemoryRootOk = $cMemoryRootOk
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
    if ($IncludeZCode) {
      Write-Host "SKILL_SYNC $($r.name) zcode=$($r.zcodeOk) codex=$($r.codexOk) zcodePackageRoot=$($r.zcodePackageRootOk) codexPackageRoot=$($r.codexPackageRootOk) zcodeMemoryRoot=$($r.zcodeMemoryRootOk) codexMemoryRoot=$($r.codexMemoryRootOk)"
    } else {
      Write-Host "SKILL_SYNC $($r.name) codex=$($r.codexOk) codexPackageRoot=$($r.codexPackageRootOk) codexMemoryRoot=$($r.codexMemoryRootOk)"
    }
  }
  if ($ok) { Write-Host 'SKILL_SYNC_OK' } else { Write-Host 'SKILL_SYNC_FAILED' }
}

if (-not $ok) { exit 1 }
exit 0
