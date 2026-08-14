function Get-SuperBrainInstallTransactionRoot([string]$PackageRoot) {
  return Join-Path (Get-SuperBrainArchiveRoot $PackageRoot) 'install-transactions'
}

function Get-SuperBrainInstallTransactionPath([string]$Path) {
  return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
}

function Test-SuperBrainWritableDirectory([string]$Path) {
  try {
    $resolved = Get-SuperBrainInstallTransactionPath $Path
    New-Item -ItemType Directory -Force -Path $resolved -ErrorAction Stop | Out-Null
    $probe = Join-Path $resolved ('.write-probe-' + [guid]::NewGuid().ToString('n'))
    [IO.File]::WriteAllText($probe, '', (New-Object Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Resolve-SuperBrainWritableTransactionRoot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [string]$RequestedRoot = ''
  )

  $package = Get-SuperBrainInstallTransactionPath $PackageRoot
  if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
    $requested = Get-SuperBrainInstallTransactionPath $RequestedRoot
    if (Test-SuperBrainWritableDirectory $requested) { return $requested }
    throw "INSTALL_TRANSACTION_ROOT_NOT_WRITABLE path=$requested"
  }

  $candidates = @(
    (Get-SuperBrainInstallTransactionRoot $package),
    (Join-Path (Get-SuperBrainMemoryBaseRoot $package) 'install-transactions'),
    (Join-Path (Split-Path -Parent $package) 'output\install-transactions')
  )
  $seen = @{}
  $failures = @()
  foreach ($candidate in @($candidates)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    $resolved = Get-SuperBrainInstallTransactionPath ([string]$candidate)
    $key = $resolved.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    if (Test-SuperBrainWritableDirectory $resolved) { return $resolved }
    $failures += $resolved
  }
  throw "INSTALL_TRANSACTION_NO_WRITABLE_ROOT candidates=$($failures -join ';')"
}

function New-SuperBrainInstallTransaction {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [Parameter(Mandatory=$true)][string[]]$TargetPaths,
    [string]$TransactionRoot = ''
  )

  $TransactionRoot = Resolve-SuperBrainWritableTransactionRoot -PackageRoot $PackageRoot -RequestedRoot $TransactionRoot
  New-Item -ItemType Directory -Force -Path $TransactionRoot | Out-Null

  $id = 'install-transaction-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('n').Substring(0,8))
  $root = Join-Path $TransactionRoot $id
  $itemsRoot = Join-Path $root 'items'
  New-Item -ItemType Directory -Force -Path $itemsRoot | Out-Null

  $seen = @{}
  $items = @()
  $index = 0
  foreach ($candidate in @($TargetPaths)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    $target = Get-SuperBrainInstallTransactionPath ([string]$candidate)
    $key = $target.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true

    $exists = Test-Path -LiteralPath $target
    $kind = if ($exists -and (Test-Path -LiteralPath $target -PathType Container)) { 'directory' } elseif ($exists) { 'file' } else { 'missing' }
    $payload = ''
    if ($exists) {
      $itemRoot = Join-Path $itemsRoot ('item-{0:d4}' -f $index)
      New-Item -ItemType Directory -Force -Path $itemRoot | Out-Null
      $payload = Join-Path $itemRoot 'payload'
      Copy-Item -LiteralPath $target -Destination $payload -Recurse -Force
      if (-not (Test-Path -LiteralPath $payload)) { throw "INSTALL_TRANSACTION_SNAPSHOT_MISSING target=$target" }
    }
    $items += [pscustomobject]@{
      target = $target
      existed = [bool]$exists
      kind = $kind
      payload = $payload
    }
    $index += 1
  }

  $manifest = [pscustomobject]@{
    schema = 'super-brain.install-transaction.v1'
    id = $id
    status = 'prepared'
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    packageRoot = (Get-SuperBrainInstallTransactionPath $PackageRoot)
    transactionRoot = $root
    items = @($items)
  }
  $manifestPath = Join-Path $root 'transaction.json'
  Write-JsonUtf8NoBom $manifestPath $manifest 10
  return [pscustomobject]@{ id=$id; root=$root; manifestPath=$manifestPath; itemCount=@($items).Count }
}

function Read-SuperBrainInstallTransaction([Parameter(Mandatory=$true)][object]$Transaction) {
  $manifestPath = if ($Transaction -is [string]) { $Transaction } else { [string]$Transaction.manifestPath }
  if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath)) {
    throw 'INSTALL_TRANSACTION_MANIFEST_MISSING'
  }
  return Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-SuperBrainInstallTransaction([object]$Manifest,[string]$ManifestPath) {
  Write-JsonUtf8NoBom $ManifestPath $Manifest 10
}

function Complete-SuperBrainInstallTransaction {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][object]$Transaction)

  $manifestPath = if ($Transaction -is [string]) { $Transaction } else { [string]$Transaction.manifestPath }
  $manifest = Read-SuperBrainInstallTransaction $Transaction
  $manifest.status = 'committed'
  $manifest | Add-Member -NotePropertyName committedAt -NotePropertyValue (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') -Force
  Save-SuperBrainInstallTransaction $manifest $manifestPath
  return [pscustomobject]@{ ok=$true; id=$manifest.id; status=$manifest.status; manifestPath=$manifestPath }
}

function Restore-SuperBrainInstallTransaction {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][object]$Transaction)

  $manifestPath = if ($Transaction -is [string]) { $Transaction } else { [string]$Transaction.manifestPath }
  $manifest = Read-SuperBrainInstallTransaction $Transaction
  $errors = @()
  foreach ($item in @($manifest.items | Sort-Object { ([string]$_.target).Length } -Descending)) {
    try {
      $target = [string]$item.target
      if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
      }
      if ($item.existed -eq $true) {
        $parent = Split-Path -Parent $target
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        if (-not (Test-Path -LiteralPath ([string]$item.payload))) { throw "INSTALL_TRANSACTION_PAYLOAD_MISSING target=$target" }
        Copy-Item -LiteralPath ([string]$item.payload) -Destination $target -Recurse -Force
      }
    } catch {
      $errors += "target=$($item.target) error=$($_.Exception.Message)"
    }
  }
  $manifest.status = if ($errors.Count -eq 0) { 'rolled_back' } else { 'rollback_incomplete' }
  $manifest | Add-Member -NotePropertyName rolledBackAt -NotePropertyValue (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') -Force
  $manifest | Add-Member -NotePropertyName rollbackErrors -NotePropertyValue @($errors) -Force
  Save-SuperBrainInstallTransaction $manifest $manifestPath
  return [pscustomobject]@{ ok=($errors.Count -eq 0); id=$manifest.id; status=$manifest.status; manifestPath=$manifestPath; errors=@($errors) }
}
