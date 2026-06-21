param(
  [switch]$Apply,
  [string]$ImportRoot = '',
  [ValidateSet('Merge','Overwrite')]
  [string]$Mode = 'Merge',
  [switch]$CleanupImport
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$DefaultImportRoot = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'merge-overlay'
$TextMemoryExtensions = @('.txt','.md','.jsonl','.log')

function Get-MemoryItemKind([System.IO.FileSystemInfo]$Item) {
  if ($Item.PSIsContainer) { return 'directory' }
  if ($TextMemoryExtensions -contains $Item.Extension.ToLowerInvariant()) { return 'text' }
  return 'binary'
}

function Merge-TextMemoryFile([string]$SourcePath, [string]$DestinationPath) {
  $sourceText = [System.IO.File]::ReadAllText($SourcePath, [System.Text.Encoding]::UTF8)
  $destinationText = [System.IO.File]::ReadAllText($DestinationPath, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($sourceText)) { return 'empty-source' }
  if ($destinationText.Contains($sourceText)) { return 'already-contained' }

  $separator = "`n`n# MIGRATED_LEGACY_MEMORY $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
  Write-Utf8NoBom $DestinationPath ($destinationText.TrimEnd() + $separator + $sourceText.TrimStart())
  return 'merged'
}

function Copy-MemoryDirectoryItems([string]$SourceDirectory, [string]$DestinationDirectory, [string]$Strategy) {
  foreach ($item in @(Get-ChildItem -LiteralPath $SourceDirectory -Force -ErrorAction SilentlyContinue)) {
    $dest = Join-Path $DestinationDirectory $item.Name
    if (-not (Test-Path $dest)) {
      Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse -Force
      Write-Host "MIGRATE_COPY item=$($item.Name)"
      continue
    }

    if ($Strategy -eq 'Overwrite') {
      Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse -Force
      Write-Host "MIGRATE_OVERWRITE item=$($item.Name)"
      continue
    }

    $kind = Get-MemoryItemKind $item
    if ($kind -eq 'text' -and -not (Test-Path $dest -PathType Container)) {
      $result = Merge-TextMemoryFile $item.FullName $dest
      Write-Host "MIGRATE_MERGE item=$($item.Name) result=$result"
    } elseif ($kind -eq 'directory' -and (Test-Path $dest -PathType Container)) {
      Copy-MemoryDirectoryItems $item.FullName $dest $Strategy
    } else {
      Write-Host "MIGRATE_KEEP_NEW item=$($item.Name) kind=$kind"
    }
  }
}

function Copy-MemoryRootIfNeeded([string]$Source, [string]$Destination, [string]$Scope, [string[]]$Members, [string]$Strategy) {
  if (-not (Test-Path $Source)) {
    Write-Host "MIGRATE_SKIP missing=$Source"
    return $false
  }
  Write-Host "MIGRATE_PLAN source=$Source destination=$Destination scope=$Scope apply=$Apply mode=$Strategy strategy=copy-new-merge-text-keep-new-or-overwrite"
  if (-not $Apply) { return $true }

  Initialize-SuperBrainMemoryRoot $Destination $Root $Scope $Members
  $sourceFull = Get-NormalizedSuperBrainRoot $Source
  $destinationFull = Get-NormalizedSuperBrainRoot $Destination
  if ($sourceFull -eq $destinationFull) { throw "MIGRATE_REFUSE_SELF source equals destination: $Source" }
  if ($sourceFull.StartsWith($destinationFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "MIGRATE_REFUSE_NESTED source is inside destination: $Source" }
  if ($destinationFull.StartsWith($sourceFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "MIGRATE_REFUSE_PARENT source contains destination: $Source" }

  Copy-MemoryDirectoryItems $Source $Destination $Strategy
  Write-SuperBrainMemoryScope $Destination $Scope $Members $Root
  Write-Host "MIGRATE_DONE source=$Source destination=$Destination mode=$Strategy"
  return $true
}

function Resolve-ImportMemoryRoot([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return $Path }
  $nested = Join-Path $Path 'memory'
  if (Test-Path $nested -PathType Container) {
    $rootItems = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'memory' })
    if ($rootItems.Count -eq 0) {
      Write-Host "MIGRATE_IMPORT_NESTED_MEMORY detected=$nested"
      return $nested
    }
  }
  return $Path
}

function Remove-ImportRootIfSafe([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return }
  $full = Get-NormalizedSuperBrainRoot $Path
  $expected = Get-NormalizedSuperBrainRoot $DefaultImportRoot
  if ($full -ne $expected) { throw "MIGRATE_CLEANUP_REFUSED import root is not the default merge-overlay directory: $full" }
  Remove-Item -LiteralPath $Path -Recurse -Force
  Write-Host "MIGRATE_IMPORT_CLEANED path=$Path"
}

$shared = Get-SuperBrainSharedMemoryRoot $Root
$zAgent = Get-SuperBrainAgentMemoryRoot 'zcode' $Root
$cAgent = Get-SuperBrainAgentMemoryRoot 'codex' $Root
$ran = $false

if (-not [string]::IsNullOrWhiteSpace($ImportRoot)) {
  $resolvedImportRoot = Resolve-ImportMemoryRoot $ImportRoot
  $ran = Copy-MemoryRootIfNeeded $resolvedImportRoot $shared 'shared' @('all-agents') $Mode
  if ($Apply -and $CleanupImport -and $ran) { Remove-ImportRootIfSafe $ImportRoot }
} else {
  $legacyShared = Join-Path $Root 'memory'
  $zLegacy = Join-Path $Root 'memory-zcode'
  $cLegacy = Join-Path $Root 'memory-codex'

  if (Copy-MemoryRootIfNeeded $legacyShared $shared 'shared' @('all-agents') $Mode) { $ran = $true }
  if (Copy-MemoryRootIfNeeded $zLegacy $zAgent 'agent' @('zcode') $Mode) { $ran = $true }
  if (Copy-MemoryRootIfNeeded $cLegacy $cAgent 'agent' @('codex') $Mode) { $ran = $true }
}

if ($Apply) {
  Write-SuperBrainSharingPolicy $Root 'shared' $shared @('all-agents') | Out-Null
  Write-Host "MIGRATE_POLICY_OK policy=$(Get-SuperBrainSharingPolicyPath $Root) active=$shared"
} else {
  Write-Host "MIGRATE_DRY_RUN use -Apply to copy old memory roots into the new layout. Put old memory under memory\merge-overlay and pass -ImportRoot '$DefaultImportRoot' for UI-style import; Mode=Merge appends text conflicts, Mode=Overwrite overwrites same-name files without deleting unrelated new files."
}
