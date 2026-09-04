$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\common.ps1')

$script:compactReport = Join-Path $root 'scripts\compact-report.ps1'
$script:compactApply = Join-Path $root 'scripts\compact-apply.ps1'
$script:autoHygiene = Join-Path $root 'scripts\auto-hygiene-runner.ps1'
$script:backupRetention = Join-Path $root 'scripts\backup-retention.ps1'
$script:vendorRoot = Join-Path $root 'vendor\NexSandglass-Agent-DedicatedMemory'

function Write-RetentionTestText([string]$Path,[string]$Text) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

function Initialize-RetentionTestState([string]$StateRoot,[string[]]$Lines) {
  $memoryRoot = Join-Path $StateRoot 'shared'
  # Keep the runtime copy inside the isolated fixture.  Copying into the
  # package vendor directory made the cold-migration test self-copy files and
  # fail before the preview-only behavior could be exercised.
  $runtimeRoot = Join-Path $StateRoot 'vendor\NexSandglass-Agent-DedicatedMemory'
  New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
  foreach ($file in @(Get-ChildItem -LiteralPath $script:vendorRoot -File -Filter '*.py')) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $runtimeRoot $file.Name) -Force
  }
  Write-RetentionTestText (Join-Path $memoryRoot 'sandglass.txt') (($Lines -join "`n") + "`n")
  return $memoryRoot
}

function Invoke-RetentionJsonScript([string]$ScriptPath,[string[]]$Arguments,[string]$StateRoot,[string]$ArchiveRoot = '') {
  $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  $oldArchiveRoot = $env:SUPER_BRAIN_ARCHIVE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) { Remove-Item Env:SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $ArchiveRoot }
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $oldStateRoot) { Remove-Item Env:SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    if ($null -eq $oldArchiveRoot) { Remove-Item Env:SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $oldArchiveRoot }
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode=$exitCode; text=$text; value=$value }
}

Describe 'RetentionGovernance' {
  It 'reports normalized duplicates without exposing raw memory by default' {
    $state = Join-Path $TestDrive 'report-state'
    $memory = Initialize-RetentionTestState $state @(
      '2026-07-20 10:00:00 | user | [PROJECT] super-secret-duplicate-alpha',
      '2026-07-21 10:00:00 | assistant | [PROJECT] super-secret-duplicate-alpha',
      '2026-07-21 10:01:00 | user | [PROJECT] retained-beta'
    )

    $report = Invoke-RetentionJsonScript $script:compactReport @('-Json') $state
    $report.exitCode | Should Be 0
    $report.value.schema | Should Be 'super-brain.memory-dedup-report.v2'
    $report.value.duplicateCount | Should Be 1
    @($report.value.duplicateGroups).Count | Should Be 1
    $report.value.samplesIncluded | Should Be $false
    $report.text.Contains('super-secret-duplicate-alpha') | Should Be $false
    $report.value.sourceHash | Should Be (Get-SuperBrainFileSha256 (Join-Path $memory 'sandglass.txt'))
  }

  It 'commits a duplicate rewrite only after hash-bound planning and derived-index rebuild' {
    $state = Join-Path $TestDrive 'apply-state'
    $memory = Initialize-RetentionTestState $state @(
      '2026-07-20 10:00:00 | user | [PROJECT] alpha duplicate',
      '2026-07-21 10:00:00 | assistant | [PROJECT] alpha duplicate',
      '2026-07-21 10:01:00 | user | [PROJECT] retained beta'
    )
    $memoryPath = Join-Path $memory 'sandglass.txt'
    $beforeHash = Get-SuperBrainFileSha256 $memoryPath
    $report = Invoke-RetentionJsonScript $script:compactReport @('-Json') $state
    $apply = Invoke-RetentionJsonScript $script:compactApply @('-Force','-Json','-ExpectedSourceHash',[string]$report.value.sourceHash,'-ExpectedPlanFingerprint',[string]$report.value.planFingerprint) $state

    $apply.exitCode | Should Be 0
    $apply.value.ok | Should Be $true
    $apply.value.status | Should Be 'committed'
    $apply.value.removed | Should Be 1
    @(Get-Content -LiteralPath $memoryPath -Encoding UTF8).Count | Should Be 2
    (Get-SuperBrainFileSha256 $apply.value.backupPath) | Should Be $beforeHash
    $receipt = Get-Content -LiteralPath $apply.value.receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $receipt.status | Should Be 'committed'
    Test-Path -LiteralPath (Join-Path $memory 'sandglass.idx') | Should Be $true
  }

  It 'restores the original memory and indexes after a fault following the swap' {
    $state = Join-Path $TestDrive 'rollback-state'
    $memory = Initialize-RetentionTestState $state @(
      '2026-07-20 10:00:00 | user | [PROJECT] rollback duplicate',
      '2026-07-21 10:00:00 | assistant | [PROJECT] rollback duplicate'
    )
    $memoryPath = Join-Path $memory 'sandglass.txt'
    $beforeHash = Get-SuperBrainFileSha256 $memoryPath
    $report = Invoke-RetentionJsonScript $script:compactReport @('-Json') $state
    $failed = Invoke-RetentionJsonScript $script:compactApply @('-Force','-Json','-FaultPoint','after_swap','-ExpectedSourceHash',[string]$report.value.sourceHash,'-ExpectedPlanFingerprint',[string]$report.value.planFingerprint) $state

    $failed.exitCode | Should Be 1
    $failed.value.status | Should Be 'failed'
    (Get-SuperBrainFileSha256 $memoryPath) | Should Be $beforeHash
    $receiptPath = Get-ChildItem -LiteralPath (Join-Path $memory 'workspace\memory-rewrite-transactions') -File -Filter 'memory-rewrite-*.json' | Select-Object -First 1 -ExpandProperty FullName
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $receipt.status | Should Be 'rolled_back'
    $receipt.rollbackVerified | Should Be $true
  }

  It 'routes automatic hygiene through the same committed rewrite transaction' {
    $state = Join-Path $TestDrive 'hygiene-state'
    $memory = Initialize-RetentionTestState $state @(
      '2026-07-20 10:00:00 | user | [PROJECT] hygiene duplicate',
      '2026-07-21 10:00:00 | assistant | [PROJECT] hygiene duplicate'
    )
    $hygiene = Invoke-RetentionJsonScript $script:autoHygiene @('-ApplySafe','-Json') $state

    $hygiene.exitCode | Should Be 0
    $hygiene.value.ok | Should Be $true
    $hygiene.value.changed | Should Be $true
    $hygiene.value.rewriteTransaction.changed | Should Be $true
    @(Get-Content -LiteralPath (Join-Path $memory 'sandglass.txt') -Encoding UTF8).Count | Should Be 1
    $receipt = Get-Content -LiteralPath $hygiene.value.rewriteTransaction.receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $receipt.status | Should Be 'committed'
  }

  It 'archives only unreferenced grace-eligible backups and restores them from a receipt' {
    $state = Join-Path $TestDrive 'retention-state'
    $archive = Join-Path $TestDrive 'retention-archive'
    $memory = Initialize-RetentionTestState $state @('2026-07-21 10:00:00 | user | [PROJECT] live memory')
    $backup = Join-Path $memory 'sandglass.txt.bak-compact-old'
    $duplicateBackup = Join-Path $memory 'sandglass.txt.bak-compact-duplicate'
    Write-RetentionTestText $backup 'backup bytes'
    Write-RetentionTestText $duplicateBackup 'backup bytes'
    (Get-Item -LiteralPath $backup).LastWriteTime = (Get-Date).AddDays(-10)
    (Get-Item -LiteralPath $duplicateBackup).LastWriteTime = (Get-Date).AddDays(-11)
    $beforeHash = Get-SuperBrainFileSha256 $backup
    $referencePath = Join-Path $state 'workspace\retention-reference.json'
    $testHookPath = Join-Path $TestDrive 'missing-hook.ps1'
    Write-RetentionTestText $referencePath ('{"backup":"' + $backup.Replace('\','\\') + '"}')

    $blocked = Invoke-RetentionJsonScript $script:backupRetention @('-Keep','0','-GraceDays','1','-HookPath',$testHookPath,'-Json') $state $archive
    $blocked.exitCode | Should Be 0
    $blockedCandidate = @($blocked.value.candidates | Where-Object { $_.path -eq $backup })[0]
    (@($blockedCandidate.blockReasons) -contains 'referenced_by_live_state') | Should Be $true

    Remove-Item -LiteralPath $referencePath -Force
    $preview = Invoke-RetentionJsonScript $script:backupRetention @('-Keep','0','-GraceDays','1','-HookPath',$testHookPath,'-Json') $state $archive
    $preview.exitCode | Should Be 0
    $previewCandidate = @($preview.value.candidates | Where-Object { $_.path -eq $backup })[0]
    $previewCandidate.eligible | Should Be $true
    $duplicateCandidate = @($preview.value.candidates | Where-Object { $_.path -eq $duplicateBackup })[0]
    (([string]$previewCandidate.dedupeRole -eq 'primary') -or ([string]$duplicateCandidate.dedupeRole -eq 'primary')) | Should Be $true
    (([string]$previewCandidate.dedupeRole -eq 'duplicate') -or ([string]$duplicateCandidate.dedupeRole -eq 'duplicate')) | Should Be $true
    $applied = Invoke-RetentionJsonScript $script:backupRetention @('-Apply','-PreviewPath',[string]$preview.value.previewPath,'-Json') $state $archive
    $applied.exitCode | Should Be 0
    $applied.value.archivedCount | Should Be 1
    $applied.value.deduplicatedCount | Should Be 1
    Test-Path -LiteralPath $backup | Should Be $false
    Test-Path -LiteralPath $duplicateBackup | Should Be $false
    $receipt = Get-Content -LiteralPath $applied.value.receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($receipt.archived).Count | Should Be 2
    $archivedPath = [string](@($receipt.archived | Where-Object { $_.storageMode -eq 'archived' })[0].archivedPath)
    (Get-SuperBrainFileSha256 $archivedPath) | Should Be $beforeHash

    $restored = Invoke-RetentionJsonScript $script:backupRetention @('-RestoreReceiptPath',[string]$applied.value.receiptPath,'-Apply','-Json') $state $archive
    $restored.exitCode | Should Be 0
    $restored.value.restoredCount | Should Be 2
    (Get-SuperBrainFileSha256 $backup) | Should Be $beforeHash
    (Get-SuperBrainFileSha256 $duplicateBackup) | Should Be $beforeHash
  }

  It 'keeps runtime cold migration preview-only even when called without dry-run' {
    $state = Join-Path $TestDrive 'cold-migration-state'
    $memory = Initialize-RetentionTestState $state @('2020-01-01 00:00:00 | assistant | old private history')
    $memoryPath = Join-Path $memory 'sandglass.txt'
    $beforeHash = Get-SuperBrainFileSha256 $memoryPath
    $oldHome = $env:NEXSANDBASE_HOME
    $oldPythonPath = $env:PYTHONPATH
    try {
      $env:NEXSANDBASE_HOME = $memory
      # Import the isolated vendor copy created by the fixture, not the
      # package's live vendor tree or a nonexistent memory/scripts folder.
      $env:PYTHONPATH = Join-Path $state 'vendor\NexSandglass-Agent-DedicatedMemory'
      $raw = @(& python -c "import json; from sandglass_archive import cold_migration; print(json.dumps(cold_migration(dry_run=False)))" 2>$null)
      $exitCode = $LASTEXITCODE
    } finally {
      if ($null -eq $oldHome) { Remove-Item Env:NEXSANDBASE_HOME -ErrorAction SilentlyContinue } else { $env:NEXSANDBASE_HOME = $oldHome }
      if ($null -eq $oldPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $oldPythonPath }
    }
    $exitCode | Should Be 0
    $result = ($raw -join "`n") | ConvertFrom-Json
    $result.moved | Should Be 0
    $result.dropped | Should Be 0
    $result.planned | Should Be 1
    $result.requiresConfirmation | Should Be $true
    (Get-SuperBrainFileSha256 $memoryPath) | Should Be $beforeHash
    Test-Path -LiteralPath (Join-Path $memory 'archive') | Should Be $false
  }
}
