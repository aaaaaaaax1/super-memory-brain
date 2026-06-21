param(
  [switch]$Apply
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ok = $true

function Get-RelativePath([string]$BasePath, [string]$Path) {
  $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
  $pathFull = [System.IO.Path]::GetFullPath($Path)
  $baseUri = [System.Uri]::new($baseFull)
  $pathUri = [System.Uri]::new($pathFull)
  return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function Test-ScopeMarker([string]$Path, [string]$Member) {
  $scopePath = Join-Path $Path '.memory-scope.json'
  if (-not (Test-Path $scopePath)) { return $false }
  try {
    $scope = Get-Content -LiteralPath $scopePath -Raw -Encoding UTF8 | ConvertFrom-Json
    return ($scope.scope -eq 'agent' -and @($scope.members) -contains $Member)
  } catch {
    return $false
  }
}

function Compare-LegacyPair([string]$Name, [string]$LegacyPath, [string]$NewPath) {
  $pairOk = $true
  if (-not (Test-Path $LegacyPath)) {
    Write-Host "LEGACY_CLEANUP_SKIP missing=$LegacyPath"
    return [pscustomobject]@{ name=$Name; ok=$true; exists=$false; legacy=$LegacyPath; target=$NewPath }
  }
  if (-not (Test-Path $NewPath)) {
    Write-Host "LEGACY_CLEANUP_FAIL missingTarget=$NewPath"
    $pairOk = $false
  }
  if (-not (Test-ScopeMarker $NewPath $Name)) {
    Write-Host "LEGACY_CLEANUP_FAIL invalidScopeMarker target=$NewPath member=$Name"
    $pairOk = $false
  }

  $legacyFiles = @(Get-ChildItem -LiteralPath $LegacyPath -Recurse -File -Force -ErrorAction SilentlyContinue)
  $mismatch = 0
  $missing = 0
  foreach ($file in $legacyFiles) {
    $rel = Get-RelativePath $LegacyPath $file.FullName
    $targetFile = Join-Path $NewPath $rel
    if (-not (Test-Path $targetFile)) {
      Write-Host "LEGACY_CLEANUP_FAIL missingMigratedFile $Name $rel"
      $missing += 1
      continue
    }
    $legacyHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
    if ($legacyHash -ne $targetHash) {
      Write-Host "LEGACY_CLEANUP_FAIL hashMismatch $Name $rel"
      $mismatch += 1
    }
  }

  if ($missing -gt 0 -or $mismatch -gt 0) { $pairOk = $false }
  Write-Host "LEGACY_CLEANUP_PAIR name=$Name ok=$pairOk legacyFiles=$($legacyFiles.Count) missing=$missing mismatch=$mismatch legacy=$LegacyPath target=$NewPath apply=$Apply"
  return [pscustomobject]@{ name=$Name; ok=$pairOk; exists=$true; legacy=$LegacyPath; target=$NewPath }
}

$statusPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-verify-package.json'
if (Test-Path $statusPath) {
  try {
    $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($status.ok -ne $true) { Write-Host "LEGACY_CLEANUP_FAIL last verify not ok: $statusPath"; $ok = $false }
  } catch {
    Write-Host "LEGACY_CLEANUP_FAIL cannot parse last verify: $statusPath"
    $ok = $false
  }
} else {
  Write-Host "LEGACY_CLEANUP_FAIL missing last verify: $statusPath"
  $ok = $false
}

$pairs = @(
  (Compare-LegacyPair 'zcode' (Join-Path $Root 'memory-zcode') (Get-SuperBrainAgentMemoryRoot 'zcode' $Root)),
  (Compare-LegacyPair 'codex' (Join-Path $Root 'memory-codex') (Get-SuperBrainAgentMemoryRoot 'codex' $Root))
)
foreach ($pair in $pairs) { if (-not $pair.ok) { $ok = $false } }

if (-not $ok) {
  Write-Host 'LEGACY_CLEANUP_BLOCKED'
  exit 1
}

if (-not $Apply) {
  Write-Host 'LEGACY_CLEANUP_DRY_RUN_OK use -Apply to delete verified legacy roots.'
  exit 0
}

foreach ($pair in $pairs) {
  if ($pair.exists -and (Test-Path $pair.legacy)) {
    $legacyFull = Get-NormalizedSuperBrainRoot $pair.legacy
    $allowed = @(
      (Get-NormalizedSuperBrainRoot (Join-Path $Root 'memory-zcode')),
      (Get-NormalizedSuperBrainRoot (Join-Path $Root 'memory-codex'))
    )
    if ($allowed -notcontains $legacyFull) { throw "Refusing to delete non-allowlisted path: $legacyFull" }
    Remove-Item -LiteralPath $pair.legacy -Recurse -Force
    Write-Host "LEGACY_CLEANUP_DELETED $($pair.legacy)"
  }
}

Write-Host 'LEGACY_CLEANUP_OK'
