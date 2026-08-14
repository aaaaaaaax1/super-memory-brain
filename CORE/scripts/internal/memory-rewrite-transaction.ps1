function Get-SuperBrainMemoryRewriteTextHash([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return -join ($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes([string]$Text)) | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha.Dispose()
  }
}

function ConvertTo-SuperBrainMemoryRewriteText([string[]]$Lines) {
  $items = @($Lines | ForEach-Object { [string]$_ })
  if ($items.Count -eq 0) { return '' }
  return (($items -join "`n") + "`n")
}

function Get-SuperBrainMemoryNormalizedDuplicateKey([string]$Line) {
  return ([string]$Line -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| [^|]+ \| ', '')
}

function Get-SuperBrainMemoryDedupPlan([string[]]$Lines) {
  $seen = @{}
  $groupsByKey = @{}
  $replacement = New-Object System.Collections.Generic.List[string]
  $lineMap = [ordered]@{}
  $lineNumber = 0
  $replacementLine = 0
  $nonBlankLines = 0
  $removed = 0

  foreach ($raw in @($Lines)) {
    $lineNumber += 1
    $line = [string]$raw
    if ([string]::IsNullOrWhiteSpace($line)) {
      [void]$replacement.Add($line)
      $replacementLine += 1
      $lineMap[[string]$lineNumber] = $replacementLine
      continue
    }

    $nonBlankLines += 1
    $key = Get-SuperBrainMemoryNormalizedDuplicateKey $line
    if ($seen.ContainsKey($key)) {
      $first = $seen[$key]
      $lineMap[[string]$lineNumber] = [int]$first.replacementLine
      [void]$first.duplicateLines.Add($lineNumber)
      $removed += 1
      continue
    }

    $replacementLine += 1
    $record = [pscustomobject]@{
      key = $key
      fingerprint = Get-SuperBrainMemoryRewriteTextHash $key
      firstLine = $lineNumber
      replacementLine = $replacementLine
      duplicateLines = New-Object System.Collections.Generic.List[int]
    }
    $seen[$key] = $record
    $groupsByKey[$key] = $record
    $lineMap[[string]$lineNumber] = $replacementLine
    [void]$replacement.Add($line)
  }

  $duplicateGroups = @($groupsByKey.Values | Where-Object { $_.duplicateLines.Count -gt 0 } | Sort-Object firstLine)
  return [pscustomobject]@{
    schema = 'super-brain.memory-dedup-plan.v1'
    totalLines = $lineNumber
    nonBlankLines = $nonBlankLines
    keptLines = $replacement.Count
    duplicateCount = $removed
    duplicateGroupCount = $duplicateGroups.Count
    duplicateGroups = $duplicateGroups
    replacementLines = @($replacement)
    replacementText = ConvertTo-SuperBrainMemoryRewriteText @($replacement)
    lineMap = $lineMap
  }
}

function Get-SuperBrainMemoryDedupFingerprint([object]$Plan,[string]$SourceHash) {
  $parts = @(
    'super-brain.memory-dedup-plan.v1',
    ([string]$SourceHash).ToLowerInvariant(),
    [string]$Plan.totalLines,
    [string]$Plan.keptLines,
    [string]$Plan.duplicateCount
  )
  foreach ($group in @($Plan.duplicateGroups | Sort-Object firstLine)) {
    $parts += ('{0}|{1}|{2}|{3}' -f [string]$group.fingerprint,[int]$group.firstLine,[int]$group.replacementLine,(@($group.duplicateLines) -join ','))
  }
  return Get-SuperBrainMemoryRewriteTextHash ($parts -join "`n")
}

function New-SuperBrainMemoryDedupReport(
  [string]$MemoryPath,
  [object]$Plan,
  [int]$MaxDuplicateGroups = 20,
  [int]$MaxSampleChars = 0,
  [switch]$IncludeSamples
) {
  if ($MaxDuplicateGroups -lt 1) { $MaxDuplicateGroups = 1 }
  if ($MaxSampleChars -lt 32) { $MaxSampleChars = 160 }
  $sourceHash = Get-SuperBrainFileSha256 $MemoryPath
  $sourceBytes = if (Test-Path -LiteralPath $MemoryPath -PathType Leaf) { [int64](Get-Item -LiteralPath $MemoryPath).Length } else { 0 }
  $allGroups = @($Plan.duplicateGroups | Sort-Object firstLine)
  $visibleGroups = @($allGroups | Select-Object -First $MaxDuplicateGroups | ForEach-Object {
    $sample = ''
    if ($IncludeSamples) {
      $value = [string]$_.key
      $sample = if ($value.Length -gt $MaxSampleChars) { $value.Substring(0,$MaxSampleChars) + '...' } else { $value }
    }
    [pscustomobject]@{
      fingerprint = [string]$_.fingerprint
      firstLine = [int]$_.firstLine
      replacementLine = [int]$_.replacementLine
      duplicateCount = @($_.duplicateLines).Count
      duplicateLines = @($_.duplicateLines | Select-Object -First 12)
      duplicateLinesTruncated = (@($_.duplicateLines).Count -gt 12)
      sample = $sample
    }
  })
  $replacementHash = Get-SuperBrainMemoryRewriteTextHash ([string]$Plan.replacementText)
  $planFingerprint = Get-SuperBrainMemoryDedupFingerprint $Plan $sourceHash
  return [pscustomobject]@{
    schema = 'super-brain.memory-dedup-report.v2'
    generatedAt = (Get-Date).ToString('o')
    memoryPath = $MemoryPath
    sourceHash = $sourceHash
    sourceBytes = $sourceBytes
    totalLines = [int]$Plan.totalLines
    nonBlankLines = [int]$Plan.nonBlankLines
    keptLines = [int]$Plan.keptLines
    duplicateCount = [int]$Plan.duplicateCount
    duplicateGroupCount = [int]$Plan.duplicateGroupCount
    duplicateGroups = $visibleGroups
    duplicateGroupsTruncated = ($allGroups.Count -gt $visibleGroups.Count)
    replacementHash = $replacementHash
    planFingerprint = $planFingerprint
    samplesIncluded = [bool]$IncludeSamples
    maxSampleChars = if ($IncludeSamples) { $MaxSampleChars } else { 0 }
  }
}

function Test-SuperBrainMemoryPathInside([string]$Child,[string]$Parent) {
  try {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $childFull = [IO.Path]::GetFullPath($Child)
    return $childFull.StartsWith($parentFull,[StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Copy-SuperBrainMemoryFileAtomically([string]$Source,[string]$Destination) {
  $directory = Split-Path -Parent $Destination
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $temp = Join-Path $directory ('.memory-rewrite-' + [guid]::NewGuid().ToString('n') + '.tmp')
  try {
    Copy-Item -LiteralPath $Source -Destination $temp -Force -ErrorAction Stop
    Move-Item -LiteralPath $temp -Destination $Destination -Force -ErrorAction Stop
  } finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
  }
}

function New-SuperBrainMemoryDerivedIndexSnapshot([string]$MemoryRoot,[string]$SnapshotRoot) {
  if (-not (Test-Path -LiteralPath $SnapshotRoot)) { New-Item -ItemType Directory -Force -Path $SnapshotRoot | Out-Null }
  $records = @()
  foreach ($name in @('sandglass.idx','sandglass.db','sandglass.db-shm','sandglass.db-wal','shadow_sand.db')) {
    $source = Join-Path $MemoryRoot $name
    $snapshot = Join-Path $SnapshotRoot $name
    $exists = Test-Path -LiteralPath $source -PathType Leaf
    if ($exists) {
      Copy-Item -LiteralPath $source -Destination $snapshot -Force -ErrorAction Stop
      $hash = Get-SuperBrainFileSha256 $source
      if ($hash -ne (Get-SuperBrainFileSha256 $snapshot)) { throw "MEMORY_REWRITE_INDEX_SNAPSHOT_HASH_MISMATCH file=$name" }
      $records += [pscustomobject]@{ name=$name; existed=$true; hash=$hash; snapshotPath=$snapshot }
    } else {
      $records += [pscustomobject]@{ name=$name; existed=$false; hash=''; snapshotPath='' }
    }
  }
  return @($records)
}

function Restore-SuperBrainMemoryDerivedIndexSnapshot([string]$MemoryRoot,[object[]]$Records) {
  foreach ($record in @($Records)) {
    $target = Join-Path $MemoryRoot ([string]$record.name)
    if ([bool]$record.existed) {
      if (-not (Test-Path -LiteralPath ([string]$record.snapshotPath) -PathType Leaf)) { throw "MEMORY_REWRITE_INDEX_ROLLBACK_SNAPSHOT_MISSING file=$($record.name)" }
      Copy-SuperBrainMemoryFileAtomically ([string]$record.snapshotPath) $target
      if ((Get-SuperBrainFileSha256 $target) -ne [string]$record.hash) { throw "MEMORY_REWRITE_INDEX_ROLLBACK_HASH_MISMATCH file=$($record.name)" }
    } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
      Remove-Item -LiteralPath $target -Force -ErrorAction Stop
    }
  }
}

function Invoke-SuperBrainMemoryIndexRebuild([string]$MemoryRoot,[hashtable]$LineMap = @{}) {
  $oldHome = $env:NEXSANDBASE_HOME
  $oldPythonPath = $env:PYTHONPATH
  try {
    $env:NEXSANDBASE_HOME = $MemoryRoot
    $env:PYTHONPATH = Get-SuperBrainRuntimePythonPath $Root
    $mappingJson = ($LineMap | ConvertTo-Json -Compress -Depth 8)
    $mapping64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($mappingJson))
    $code = "import base64,json; from sandglass_archive import rebuild_indexes; mapping=json.loads(base64.b64decode('$mapping64').decode('utf-8')); print(json.dumps(rebuild_indexes(mapping), ensure_ascii=False))"
    $raw = @(& python -c $code 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    if ($exitCode -ne 0) { return [pscustomobject]@{ ok=$false; error="python_exit=$exitCode"; output=$text } }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ ok=$false; error='empty_rebuild_result'; output='' } }
    try { $value = ConvertFrom-SuperBrainJsonOutput $text 'memory index rebuild' } catch { return [pscustomobject]@{ ok=$false; error='invalid_rebuild_result'; output=$text } }
    if ($value.ok -ne $true) { return [pscustomobject]@{ ok=$false; error='rebuild_reported_failure'; output=$text; value=$value } }
    return [pscustomobject]@{ ok=$true; value=$value; output=$text }
  } catch {
    return [pscustomobject]@{ ok=$false; error=$_.Exception.Message; output='' }
  } finally {
    if ($null -eq $oldHome) { Remove-Item Env:NEXSANDBASE_HOME -ErrorAction SilentlyContinue } else { $env:NEXSANDBASE_HOME = $oldHome }
    if ($null -eq $oldPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $oldPythonPath }
  }
}

function Invoke-SuperBrainMemoryRewriteTransaction {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$MemoryRoot,
    [Parameter(Mandatory=$true)][string]$MemoryPath,
    [Parameter(Mandatory=$true)][string]$ReplacementText,
    [string]$ExpectedSourceHash = '',
    [hashtable]$LineMap = @{},
    [string]$TransactionKind = 'rewrite',
    [string]$EvidencePath = '',
    [string]$ExpectedEvidenceHash = '',
    [ValidateSet('none','after_backup','after_swap','after_rebuild')][string]$FaultPoint = 'none'
  )

  $memoryRootFull = [IO.Path]::GetFullPath($MemoryRoot)
  $memoryPathFull = [IO.Path]::GetFullPath($MemoryPath)
  if (-not (Test-SuperBrainMemoryPathInside $memoryPathFull $memoryRootFull)) { throw "MEMORY_REWRITE_PATH_OUTSIDE_ROOT path=$memoryPathFull root=$memoryRootFull" }
  if (-not (Test-Path -LiteralPath $memoryPathFull -PathType Leaf)) { throw "MEMORY_REWRITE_SOURCE_MISSING path=$memoryPathFull" }
  $safeKind = ($TransactionKind -replace '[^A-Za-z0-9._-]','-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeKind)) { $safeKind = 'rewrite' }
  $transactionRoot = Join-Path $memoryRootFull 'workspace\memory-rewrite-transactions'
  if (-not (Test-Path -LiteralPath $transactionRoot)) { New-Item -ItemType Directory -Force -Path $transactionRoot | Out-Null }

  return Invoke-SuperBrainFileLock $memoryPathFull {
    $sourceHash = Get-SuperBrainFileSha256 $memoryPathFull
    if ([string]::IsNullOrWhiteSpace($sourceHash)) { throw "MEMORY_REWRITE_SOURCE_HASH_MISSING path=$memoryPathFull" }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceHash) -and -not [string]::Equals($sourceHash,$ExpectedSourceHash,[StringComparison]::OrdinalIgnoreCase)) {
      throw "MEMORY_REWRITE_SOURCE_HASH_MISMATCH expected=$ExpectedSourceHash actual=$sourceHash"
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
      if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) { throw "MEMORY_REWRITE_EVIDENCE_MISSING path=$EvidencePath" }
      $actualEvidenceHash = Get-SuperBrainFileSha256 $EvidencePath
      if ([string]::IsNullOrWhiteSpace($actualEvidenceHash)) { throw "MEMORY_REWRITE_EVIDENCE_HASH_MISSING path=$EvidencePath" }
      if (-not [string]::IsNullOrWhiteSpace($ExpectedEvidenceHash) -and -not [string]::Equals($actualEvidenceHash,$ExpectedEvidenceHash,[StringComparison]::OrdinalIgnoreCase)) {
        throw "MEMORY_REWRITE_EVIDENCE_HASH_MISMATCH expected=$ExpectedEvidenceHash actual=$actualEvidenceHash"
      }
    } else {
      $actualEvidenceHash = ''
    }

    $transactionId = [guid]::NewGuid().ToString('n')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $backupPath = "$memoryPathFull.bak-$safeKind-$stamp-$transactionId"
    $rollbackRoot = Join-Path $transactionRoot ('rollback-' + $transactionId)
    $receiptPath = Join-Path $transactionRoot ('memory-rewrite-' + $transactionId + '.json')
    $replacementHash = Get-SuperBrainMemoryRewriteTextHash $ReplacementText
    $temporaryPath = Join-Path (Split-Path -Parent $memoryPathFull) ('.memory-rewrite-' + $transactionId + '.tmp')
    $indexSnapshot = @()
    $rebuild = $null
    $swapped = $false
    $receipt = [ordered]@{
      schema = 'super-brain.memory-rewrite-transaction.v1'
      transactionId = $transactionId
      status = 'prepared'
      transactionKind = $safeKind
      createdAt = (Get-Date).ToString('o')
      memoryPath = $memoryPathFull
      sourceHash = $sourceHash
      replacementHash = $replacementHash
      backupPath = $backupPath
      evidencePath = $EvidencePath
      evidenceHash = $actualEvidenceHash
      rollbackRoot = $rollbackRoot
      lineMapEntries = @($LineMap.Keys).Count
      rebuild = $null
      error = ''
    }

    try {
      Copy-Item -LiteralPath $memoryPathFull -Destination $backupPath -Force -ErrorAction Stop
      if ((Get-SuperBrainFileSha256 $backupPath) -ne $sourceHash) { throw 'MEMORY_REWRITE_BACKUP_HASH_MISMATCH' }
      $indexSnapshot = @(New-SuperBrainMemoryDerivedIndexSnapshot $memoryRootFull $rollbackRoot)
      $receipt.indexSnapshot = @($indexSnapshot | ForEach-Object { [pscustomobject]@{ name=$_.name; existed=$_.existed; hash=$_.hash } })
      Write-JsonUtf8NoBom $receiptPath ([pscustomobject]$receipt) 10
      if ($FaultPoint -eq 'after_backup') { throw 'MEMORY_REWRITE_FAULT_AFTER_BACKUP' }

      [IO.File]::WriteAllText($temporaryPath,$ReplacementText,[Text.UTF8Encoding]::new($false))
      if ((Get-SuperBrainFileSha256 $temporaryPath) -ne $replacementHash) { throw 'MEMORY_REWRITE_STAGED_HASH_MISMATCH' }
      Move-Item -LiteralPath $temporaryPath -Destination $memoryPathFull -Force -ErrorAction Stop
      $swapped = $true
      if ((Get-SuperBrainFileSha256 $memoryPathFull) -ne $replacementHash) { throw 'MEMORY_REWRITE_COMMIT_HASH_MISMATCH' }
      if ($FaultPoint -eq 'after_swap') { throw 'MEMORY_REWRITE_FAULT_AFTER_SWAP' }

      $rebuild = Invoke-SuperBrainMemoryIndexRebuild $memoryRootFull $LineMap
      if (-not $rebuild.ok) { throw "MEMORY_REWRITE_INDEX_REBUILD_FAILED error=$($rebuild.error)" }
      if ($FaultPoint -eq 'after_rebuild') { throw 'MEMORY_REWRITE_FAULT_AFTER_REBUILD' }
      if ((Get-SuperBrainFileSha256 $memoryPathFull) -ne $replacementHash) { throw 'MEMORY_REWRITE_POST_REBUILD_HASH_MISMATCH' }

      $receipt.status = 'committed'
      $receipt.committedAt = (Get-Date).ToString('o')
      $receipt.rebuild = $rebuild.value
      Write-JsonUtf8NoBom $receiptPath ([pscustomobject]$receipt) 12
      return [pscustomobject]@{
        ok = $true
        changed = $true
        transactionId = $transactionId
        receiptPath = $receiptPath
        backupPath = $backupPath
        sourceHash = $sourceHash
        replacementHash = $replacementHash
        indexRebuild = $rebuild.value
      }
    } catch {
      $failure = $_.Exception.Message
      $rollbackVerified = $false
      $rollbackError = ''
      try {
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
          Copy-SuperBrainMemoryFileAtomically $backupPath $memoryPathFull
          Restore-SuperBrainMemoryDerivedIndexSnapshot $memoryRootFull $indexSnapshot
          $rollbackVerified = ((Get-SuperBrainFileSha256 $memoryPathFull) -eq $sourceHash)
          if (-not $rollbackVerified) { throw 'MEMORY_REWRITE_ROLLBACK_SOURCE_HASH_MISMATCH' }
        } else {
          $rollbackError = 'backup_missing'
        }
      } catch {
        $rollbackError = $_.Exception.Message
      }
      $receipt.status = if ($rollbackVerified) { 'rolled_back' } else { 'rollback_failed' }
      $receipt.failedAt = (Get-Date).ToString('o')
      $receipt.error = $failure
      $receipt.rollbackVerified = $rollbackVerified
      $receipt.rollbackError = $rollbackError
      if ($rebuild) { $receipt.rebuild = $rebuild }
      try { Write-JsonUtf8NoBom $receiptPath ([pscustomobject]$receipt) 12 } catch {}
      throw "MEMORY_REWRITE_TRANSACTION_FAILED kind=$safeKind rollbackVerified=$rollbackVerified error=$failure rollbackError=$rollbackError"
    } finally {
      if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
  }
}
