[CmdletBinding()]
param(
  [ValidateRange(0,10000)][int]$Keep = 10,
  [ValidateRange(0,36500)][int]$MaxAgeDays = 0,
  [ValidateRange(0,36500)][int]$GraceDays = 7,
  [switch]$Apply,
  [string]$PreviewPath = '',
  [string]$RestoreReceiptPath = '',
  [string]$HookPath = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$archiveRoot = Get-SuperBrainWritableArchiveRoot $Root
$retentionRoot = Join-Path $archiveRoot 'backup-retention'
$previewRoot = Join-Path $retentionRoot 'previews'
$receiptRoot = Join-Path $retentionRoot 'receipts'
$archiveDestinationRoot = Join-Path $retentionRoot 'archived'
foreach ($path in @($previewRoot,$receiptRoot,$archiveDestinationRoot)) {
  if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
}

$cutoff = if ($MaxAgeDays -gt 0) { (Get-Date).AddDays(-1 * $MaxAgeDays) } else { $null }
$graceCutoff = (Get-Date).AddDays(-1 * $GraceDays)
$candidateMap = @{}
$reports = @()

function Get-SuperBrainRetentionHash([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  if (Test-Path -LiteralPath $Path -PathType Leaf) { return Get-SuperBrainFileSha256 $Path }
  $parts = New-Object System.Collections.Generic.List[string]
  $rootFull = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
  foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName)) {
    $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\','/').Replace('\','/')
    [void]$parts.Add(($relative + '|' + [string]$file.Length + '|' + (Get-SuperBrainFileSha256 $file.FullName)))
  }
  return Get-SuperBrainStableHash ($parts -join "`n") 64
}

function Get-SuperBrainRetentionPreviewFingerprint([object[]]$Candidates) {
  $parts = @('super-brain.backup-retention-preview.v2')
  foreach ($candidate in @($Candidates | Sort-Object path)) {
    $parts += ('{0}|{1}|{2}|{3}|{4}|{5}' -f [string]$candidate.path,[string]$candidate.hash,[string]$candidate.category,[bool]$candidate.eligible,[string]$candidate.dedupeRole,(@($candidate.blockReasons) -join ','))
  }
  return Get-SuperBrainStableHash ($parts -join "`n") 64
}

function Add-Candidates([string]$Name,[object[]]$Items) {
  $sorted = @($Items | Sort-Object LastWriteTime -Descending)
  $byCount = 0
  $byAge = 0
  for ($i = 0; $i -lt $sorted.Count; $i += 1) {
    $item = $sorted[$i]
    $removeByCount = $i -ge $script:Keep
    $removeByAge = ($null -ne $script:cutoff -and $item.LastWriteTime -lt $script:cutoff)
    if (-not ($removeByCount -or $removeByAge)) { continue }
    $key = [IO.Path]::GetFullPath($item.FullName)
    if (-not $script:candidateMap.ContainsKey($key)) {
      $script:candidateMap[$key] = [pscustomobject]@{
        path = $key
        name = $item.Name
        category = New-Object System.Collections.Generic.List[string]
        lastWriteTime = $item.LastWriteTime.ToString('o')
        bytes = if ($item.PSIsContainer) { 0 } else { [int64]$item.Length }
        isDirectory = [bool]$item.PSIsContainer
        removeByCount = $false
        removeByAge = $false
      }
    }
    $entry = $script:candidateMap[$key]
    if (-not $entry.category.Contains($Name)) { [void]$entry.category.Add($Name) }
    $entry.removeByCount = [bool]($entry.removeByCount -or $removeByCount)
    $entry.removeByAge = [bool]($entry.removeByAge -or $removeByAge)
    if ($removeByCount) { $byCount += 1 }
    if ($removeByAge) { $byAge += 1 }
  }
  $script:reports += [pscustomobject]@{ name=$Name; total=$sorted.Count; keep=$script:Keep; byCount=$byCount; byAge=$byAge }
}

function Test-SuperBrainRetentionReference([string]$CandidatePath) {
  $needle = [IO.Path]::GetFullPath($CandidatePath)
  $seen = @{}
  $hits = New-Object System.Collections.Generic.List[string]
  $scanned = 0
  $roots = @($memoryBase,$archiveRoot,$Root)
  foreach ($rootPath in @($roots | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      if ($file.FullName -eq $needle) { continue }
      if ($file.FullName.StartsWith($retentionRoot,[StringComparison]::OrdinalIgnoreCase)) { continue }
      if ($file.FullName -match '[\\/]\.git[\\/]') { continue }
      if ($seen.ContainsKey($file.FullName)) { continue }
      $seen[$file.FullName] = $true
      if ($file.Length -gt 8MB -or $file.Extension -notin @('.json','.jsonl','.md','.txt','.ps1','.log')) { continue }
      $scanned += 1
      try {
        $content = [IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8).Replace('\\','\')
        if ($content.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
          [void]$hits.Add($file.FullName)
          if ($hits.Count -ge 8) { break }
        }
      } catch {}
    }
    if ($hits.Count -ge 8) { break }
  }
  return [pscustomobject]@{ referenced=($hits.Count -gt 0); references=@($hits); scannedFiles=$scanned }
}

function New-SuperBrainRetentionPreview([switch]$Write) {
  $archiveBackupRoot = Join-Path $archiveRoot 'backups'
  $archiveBackups = if (Test-Path -LiteralPath $archiveBackupRoot) { @(Get-ChildItem -LiteralPath $archiveBackupRoot -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue) } else { @() }
  $legacyPackageBackups = @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue)
  Add-Candidates 'archive-backup-dirs' $archiveBackups
  Add-Candidates 'legacy-package-backup-dirs' $legacyPackageBackups

  $memoryPath = Join-Path (Get-SuperBrainActiveMemoryRoot $Root) 'sandglass.txt'
  $memoryDir = Split-Path -Parent $memoryPath
  $memoryBackups = if (Test-Path -LiteralPath $memoryDir) { @(Get-ChildItem -LiteralPath $memoryDir -File -Filter 'sandglass.txt.bak-*' -ErrorAction SilentlyContinue) } else { @() }
  Add-Candidates 'memory-rewrite-backups' $memoryBackups

  $hookPath = Get-SuperBrainHookPath $HookPath
  $hookDir = Split-Path -Parent $hookPath
  $hookName = Split-Path -Leaf $hookPath
  $hookBackups = if (Test-Path -LiteralPath $hookDir) { @(Get-ChildItem -LiteralPath $hookDir -File -Filter "$hookName.bak-super-memory-brain-*" -ErrorAction SilentlyContinue) } else { @() }
  Add-Candidates 'session-start-hook-backups' $hookBackups

  $candidates = @()
  foreach ($entry in @($candidateMap.Values | Sort-Object path)) {
    $blockReasons = New-Object System.Collections.Generic.List[string]
    $exists = Test-Path -LiteralPath $entry.path
    $hash = if ($exists) { Get-SuperBrainRetentionHash $entry.path } else { '' }
    if (-not $exists -or [string]::IsNullOrWhiteSpace($hash)) { [void]$blockReasons.Add('candidate_missing_or_unreadable') }
    $lastWrite = if ($exists) { (Get-Item -LiteralPath $entry.path).LastWriteTime } else { [datetime]::MinValue }
    $graceSatisfied = ($lastWrite -le $graceCutoff)
    if (-not $graceSatisfied) { [void]$blockReasons.Add('grace_period_not_elapsed') }
    $reference = if ($exists) { Test-SuperBrainRetentionReference $entry.path } else { [pscustomobject]@{ referenced=$false; references=@(); scannedFiles=0 } }
    if ($reference.referenced) { [void]$blockReasons.Add('referenced_by_live_state') }
    $candidates += [pscustomobject]@{
      path = $entry.path
      name = $entry.name
      category = @($entry.category)
      isDirectory = [bool]$entry.isDirectory
      bytes = [int64]$entry.bytes
      lastWriteTime = if ($exists) { $lastWrite.ToString('o') } else { $entry.lastWriteTime }
      hash = $hash
      removeByCount = [bool]$entry.removeByCount
      removeByAge = [bool]$entry.removeByAge
      graceSatisfied = $graceSatisfied
      referenceScanFiles = [int]$reference.scannedFiles
      references = @($reference.references)
      blockReasons = @($blockReasons)
      eligible = ($blockReasons.Count -eq 0)
      dedupeRole = 'not_applicable'
      duplicateOf = ''
    }
  }

  $primaryByHash = @{}
  foreach ($candidate in @($candidates | Where-Object { $_.eligible -and -not $_.isDirectory } | Sort-Object @{Expression={ [datetime]$_.lastWriteTime };Descending=$true},path)) {
    if ($primaryByHash.ContainsKey([string]$candidate.hash)) {
      $candidate.dedupeRole = 'duplicate'
      $candidate.duplicateOf = [string]$primaryByHash[[string]$candidate.hash].path
    } else {
      $candidate.dedupeRole = 'primary'
      $primaryByHash[[string]$candidate.hash] = $candidate
    }
  }

  $preview = [ordered]@{
    schema = 'super-brain.backup-retention-preview.v2'
    createdAt = (Get-Date).ToString('o')
    packageRoot = $Root
    archiveRoot = $archiveRoot
    keep = $Keep
    maxAgeDays = $MaxAgeDays
    graceDays = $GraceDays
    reports = @($reports)
    candidateCount = $candidates.Count
    eligibleCount = @($candidates | Where-Object { $_.eligible }).Count
    dedupeCandidateCount = @($candidates | Where-Object { $_.dedupeRole -eq 'duplicate' }).Count
    blockedCount = @($candidates | Where-Object { -not $_.eligible }).Count
    candidates = @($candidates)
  }
  $preview.previewFingerprint = Get-SuperBrainRetentionPreviewFingerprint @($candidates)
  $path = Join-Path $previewRoot ('backup-retention-preview-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + [guid]::NewGuid().ToString('n').Substring(0,8) + '.json')
  if ($Write) { Write-JsonUtf8NoBom $path ([pscustomobject]$preview) 12 }
  return [pscustomobject]@{ preview=[pscustomobject]$preview; previewPath=$path }
}

function Read-SuperBrainRetentionPreview([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "BACKUP_RETENTION_PREVIEW_MISSING path=$Path" }
  $preview = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$preview.schema -ne 'super-brain.backup-retention-preview.v2') { throw "BACKUP_RETENTION_PREVIEW_SCHEMA_INVALID path=$Path" }
  return $preview
}

function Invoke-SuperBrainRetentionArchive([object]$Preview,[string]$SourcePreviewPath) {
  $transactionId = [guid]::NewGuid().ToString('n')
  $destinationRoot = Join-Path $archiveDestinationRoot ((Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + $transactionId.Substring(0,8))
  New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
  $archived = @()
  $blocked = @()
  $canonicalArchives = @{}
  $orderedCandidates = @($Preview.candidates | Where-Object { $_.eligible } | Sort-Object @{Expression={ if($_.dedupeRole -eq 'primary'){0}elseif($_.dedupeRole -eq 'duplicate'){1}else{0} }},path)
  foreach ($candidate in $orderedCandidates) {
    $path = [string]$candidate.path
    if (-not (Test-Path -LiteralPath $path)) { $blocked += [pscustomobject]@{ path=$path; reason='candidate_missing_before_apply' }; continue }
    $actualHash = Get-SuperBrainRetentionHash $path
    if (-not [string]::Equals($actualHash,[string]$candidate.hash,[StringComparison]::OrdinalIgnoreCase)) { $blocked += [pscustomobject]@{ path=$path; reason='candidate_hash_changed_before_apply' }; continue }
    $reference = Test-SuperBrainRetentionReference $path
    if ($reference.referenced) { $blocked += [pscustomobject]@{ path=$path; reason='referenced_by_live_state_before_apply'; references=@($reference.references) }; continue }
    if ([string]$candidate.dedupeRole -eq 'duplicate') {
      $canonical = $canonicalArchives[[string]$candidate.hash]
      if (-not $canonical -or -not (Test-Path -LiteralPath ([string]$canonical.archivedPath) -PathType Leaf) -or -not [string]::Equals((Get-SuperBrainRetentionHash ([string]$canonical.archivedPath)),$actualHash,[StringComparison]::OrdinalIgnoreCase)) {
        $blocked += [pscustomobject]@{ path=$path; reason='dedupe_primary_missing_or_invalid' }
        continue
      }
      Remove-Item -LiteralPath $path -Force -ErrorAction Stop
      $archived += [pscustomobject]@{ originalPath=$path; archivedPath=[string]$canonical.archivedPath; hash=$actualHash; category=@($candidate.category); isDirectory=$false; storageMode='deduplicated_reference'; canonicalOriginalPath=[string]$canonical.originalPath }
      continue
    }
    $name = (($candidate.category -join '-') -replace '[^A-Za-z0-9._-]','-') + '-' + ([IO.Path]::GetFileName($path))
    $target = Join-Path $destinationRoot ($name + '-' + [guid]::NewGuid().ToString('n').Substring(0,8))
    Move-Item -LiteralPath $path -Destination $target -ErrorAction Stop
    $archivedHash = Get-SuperBrainRetentionHash $target
    if (-not [string]::Equals($archivedHash,$actualHash,[StringComparison]::OrdinalIgnoreCase)) {
      throw "BACKUP_RETENTION_ARCHIVE_HASH_MISMATCH source=$path target=$target"
    }
    $entry = [pscustomobject]@{ originalPath=$path; archivedPath=$target; hash=$archivedHash; category=@($candidate.category); isDirectory=[bool]$candidate.isDirectory; storageMode='archived'; canonicalOriginalPath='' }
    $archived += $entry
    if (-not [bool]$candidate.isDirectory) { $canonicalArchives[$archivedHash] = $entry }
  }
  $receipt = [ordered]@{
    schema = 'super-brain.backup-retention-receipt.v1'
    transactionId = $transactionId
    status = if ($blocked.Count -eq 0) { 'archived' } else { 'partial_archived' }
    createdAt = (Get-Date).ToString('o')
    previewPath = $SourcePreviewPath
    previewFingerprint = [string]$Preview.previewFingerprint
    archiveDestination = $destinationRoot
    archived = @($archived)
    archivedCount = @($archived | Where-Object { $_.storageMode -eq 'archived' }).Count
    deduplicatedCount = @($archived | Where-Object { $_.storageMode -eq 'deduplicated_reference' }).Count
    blocked = @($blocked)
    recovery = 'Run backup-retention.ps1 -RestoreReceiptPath <receipt> -Apply to restore hash-verified archived backups without overwriting an existing source.'
  }
  $receiptPath = Join-Path $receiptRoot ('backup-retention-receipt-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + $transactionId.Substring(0,8) + '.json')
  Write-JsonUtf8NoBom $receiptPath ([pscustomobject]$receipt) 12
  return [pscustomobject]@{ receipt=[pscustomobject]$receipt; receiptPath=$receiptPath }
}

function Invoke-SuperBrainRetentionRestore([string]$ReceiptPath,[switch]$Write) {
  if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "BACKUP_RETENTION_RECEIPT_MISSING path=$ReceiptPath" }
  $receipt = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$receipt.schema -ne 'super-brain.backup-retention-receipt.v1') { throw "BACKUP_RETENTION_RECEIPT_SCHEMA_INVALID path=$ReceiptPath" }
  $items = @()
  foreach ($item in @($receipt.archived)) {
    $archiveExists = Test-Path -LiteralPath ([string]$item.archivedPath)
    $sourceExists = Test-Path -LiteralPath ([string]$item.originalPath)
    $actualHash = if ($archiveExists) { Get-SuperBrainRetentionHash ([string]$item.archivedPath) } else { '' }
    $ready = ($archiveExists -and -not $sourceExists -and [string]::Equals($actualHash,[string]$item.hash,[StringComparison]::OrdinalIgnoreCase))
    $items += [pscustomobject]@{ originalPath=[string]$item.originalPath; archivedPath=[string]$item.archivedPath; hash=[string]$item.hash; isDirectory=[bool]$item.isDirectory; storageMode=[string]$item.storageMode; ready=$ready; reason=if(-not $archiveExists){'archive_missing'}elseif($sourceExists){'source_already_exists'}elseif(-not [string]::Equals($actualHash,[string]$item.hash,[StringComparison]::OrdinalIgnoreCase)){'archive_hash_mismatch'}else{''} }
  }
  if (-not $Write) { return [pscustomobject]@{ ok=$true; action='restore_preview'; receiptPath=$ReceiptPath; restorableCount=@($items | Where-Object { $_.ready }).Count; blockedCount=@($items | Where-Object { -not $_.ready }).Count; items=@($items) } }
  $restored = @(); $blocked = @()
  foreach ($item in @($items | Sort-Object @{Expression={ if($_.storageMode -eq 'deduplicated_reference'){0}else{1} }},originalPath)) {
    if (-not $item.ready) { $blocked += $item; continue }
    $parent = Split-Path -Parent $item.originalPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if ($item.storageMode -eq 'deduplicated_reference') {
      Copy-Item -LiteralPath $item.archivedPath -Destination $item.originalPath -Force -ErrorAction Stop
    } else {
      Move-Item -LiteralPath $item.archivedPath -Destination $item.originalPath -ErrorAction Stop
    }
    if (-not [string]::Equals((Get-SuperBrainRetentionHash $item.originalPath),$item.hash,[StringComparison]::OrdinalIgnoreCase)) { throw "BACKUP_RETENTION_RESTORE_HASH_MISMATCH path=$($item.originalPath)" }
    $restored += $item
  }
  return [pscustomobject]@{ ok=($blocked.Count -eq 0); action='restore'; receiptPath=$ReceiptPath; restoredCount=$restored.Count; blockedCount=$blocked.Count; restored=@($restored); blocked=@($blocked) }
}

function Write-SuperBrainRetentionResult([object]$Result) {
  if ($Json) {
    $Result | ConvertTo-Json -Depth 12
    return
  }
  Write-Host "BACKUP_RETENTION action=$($Result.action) ok=$($Result.ok) candidates=$($Result.candidateCount) eligible=$($Result.eligibleCount) blocked=$($Result.blockedCount)"
  if ($Result.PSObject.Properties['previewPath'] -and $Result.previewPath) { Write-Host "BACKUP_RETENTION_PREVIEW path=$($Result.previewPath)" }
  if ($Result.PSObject.Properties['receiptPath'] -and $Result.receiptPath) { Write-Host "BACKUP_RETENTION_RECEIPT path=$($Result.receiptPath)" }
  foreach ($item in @($Result.candidates | Select-Object -First 20)) { Write-Host "BACKUP_RETENTION_CANDIDATE eligible=$($item.eligible) path=$($item.path) reasons=$(@($item.blockReasons) -join ',')" }
}

try {
  if (-not [string]::IsNullOrWhiteSpace($RestoreReceiptPath)) {
    $restore = Invoke-SuperBrainRetentionRestore $RestoreReceiptPath -Write:$Apply
    Write-SuperBrainRetentionResult $restore
    exit $(if ($restore.ok) { 0 } else { 1 })
  }

  $previewBundle = if ([string]::IsNullOrWhiteSpace($PreviewPath)) { New-SuperBrainRetentionPreview -Write } else { [pscustomobject]@{ preview=(Read-SuperBrainRetentionPreview $PreviewPath); previewPath=$PreviewPath } }
  $preview = $previewBundle.preview
  if (-not $Apply) {
    $result = [pscustomobject]@{ ok=$true; action='preview'; previewPath=$previewBundle.previewPath; candidateCount=[int]$preview.candidateCount; eligibleCount=[int]$preview.eligibleCount; blockedCount=[int]$preview.blockedCount; previewFingerprint=[string]$preview.previewFingerprint; candidates=@($preview.candidates); reports=@($preview.reports); guard='Preview only. Apply archives only unchanged, unreferenced, grace-eligible candidates and writes a recovery receipt; it never directly deletes a backup.' }
    Write-SuperBrainRetentionResult $result
    exit 0
  }

  $applied = Invoke-SuperBrainRetentionArchive $preview $previewBundle.previewPath
  $result = [pscustomobject]@{ ok=$true; action='archive'; previewPath=$previewBundle.previewPath; receiptPath=$applied.receiptPath; candidateCount=[int]$preview.candidateCount; eligibleCount=[int]$preview.eligibleCount; blockedCount=@($applied.receipt.blocked).Count; archivedCount=[int]$applied.receipt.archivedCount; deduplicatedCount=[int]$applied.receipt.deduplicatedCount; candidates=@($preview.candidates); guard='Backups were moved to private archive only after preview, hash, reference, and grace checks. Exact duplicate files retain one canonical archived copy plus a recovery reference; use the receipt to restore.' }
  Write-SuperBrainRetentionResult $result
  exit $(if ($result.ok) { 0 } else { 1 })
} catch {
  $result = [pscustomobject]@{ ok=$false; action='failed'; candidateCount=0; eligibleCount=0; blockedCount=0; error=$_.Exception.Message }
  Write-SuperBrainRetentionResult $result
  exit 1
}
