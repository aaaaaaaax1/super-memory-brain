param(
  # `-Apply` is retained as an explicit compatibility switch; it never deletes memory.
  [switch]$Apply,
  [string]$EpochId = '',
  [switch]$Destroy
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
$legacyRoots = @(
  (Join-Path $Root 'memory-zcode'),
  (Join-Path $Root 'memory-codex'),
  (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'agents\zcode'),
  (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'agents\codex')
)
$existing = @($legacyRoots | Where-Object { Test-Path -LiteralPath $_ })

Write-Host "LEGACY_MEMORY_RETENTION_OK activeSharedRoot=$sharedRoot legacyRoots=$($existing.Count)"
foreach ($path in $existing) {
  # Read-only evidence: identify one retained artifact without copying, moving,
  # deleting, or treating the legacy root as an active memory source.
  $sample = Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  $sampleHash = ''
  if ($null -ne $sample) {
    try { $sampleHash = (Get-FileHash -LiteralPath $sample.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } catch { $sampleHash = '' }
  }
  Write-Host "LEGACY_MEMORY_READ_ONLY path=$path sampleSha256=$sampleHash"
}

if ($Apply -or $Destroy) {
  Write-Host 'LEGACY_MEMORY_DELETE_RETIRED no historical memory was deleted. Export or archive it outside the active package only after a separate, explicitly scoped user request.'
} else {
  Write-Host 'LEGACY_MEMORY_DRY_RUN_OK legacy roots are retained as read-only migration evidence.'
}

exit 0
