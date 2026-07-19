$script:SkillCatalogExcludedDirectoryNames = @(
  '.removed-backup',
  '.repair-backups',
  '.backup',
  '.backups',
  '.archive',
  '.archives',
  'manifests'
)

function Test-SkillCatalogPathExcluded([string]$Root,[string]$Candidate) {
  try {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    if (-not $candidateFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    $relative = $candidateFull.Substring($rootFull.Length)
    foreach($segment in @($relative -split '[\\/]')) {
      if ($script:SkillCatalogExcludedDirectoryNames -contains $segment.ToLowerInvariant()) { return $true }
    }
  } catch { return $true }
  return $false
}

function Get-SkillCatalogDirectories([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root)) { return @() }
  return @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-SkillCatalogPathExcluded $Root $_.FullName) } |
    Sort-Object FullName -Unique)
}

function Get-SkillCatalogFiles([string]$Root) {
  $files = @()
  $direct = Join-Path $Root 'SKILL.md'
  if (Test-Path -LiteralPath $direct -PathType Leaf) { $files += Get-Item -LiteralPath $direct -Force }
  foreach ($directory in @(Get-SkillCatalogDirectories $Root)) {
    $files += @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -Filter 'SKILL.md' -File -Force -ErrorAction SilentlyContinue |
      Where-Object { -not (Test-SkillCatalogPathExcluded $Root $_.FullName) })
  }
  return @($files | Sort-Object FullName -Unique)
}
