function Get-VerifyPackageResultHash([object]$Result) {
  if ($null -eq $Result -or $null -eq $Result.PSObject) { return '' }
  $canonical = [ordered]@{}
  foreach ($property in @($Result.PSObject.Properties)) {
    if ([string]$property.Name -ne 'statusHash') { $canonical[[string]$property.Name] = $property.Value }
  }
  return Get-SuperBrainStableHash ($canonical | ConvertTo-Json -Depth 16 -Compress) 64
}

function New-VerifyPackageReceiptCheck([bool]$Ok,[string]$Error,[object]$Receipt=$null,[string]$ReceiptText='') {
  return [pscustomobject]@{
    ok = $Ok
    error = $Error
    receipt = $Receipt
    receiptText = $ReceiptText
  }
}

function Clear-VerifyPackageResultReceipt([string]$ReceiptPath) {
  if ([string]::IsNullOrWhiteSpace($ReceiptPath)) { return $false }
  try {
    if (Test-Path -LiteralPath $ReceiptPath -PathType Container) { return $false }
    if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) {
      Remove-Item -LiteralPath $ReceiptPath -Force -ErrorAction Stop
    }
    return -not (Test-Path -LiteralPath $ReceiptPath)
  } catch {
    return $false
  }
}

function Test-VerifyPackageResultReceipt([string]$ReceiptPath,[string]$ExpectedRunId) {
  if ([string]::IsNullOrWhiteSpace($ExpectedRunId)) {
    return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_RUN_ID_REQUIRED'
  }
  if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
    return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_MISSING'
  }
  $receiptText = ''
  $receipt = $null
  try {
    $receiptText = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($receiptText)) {
      return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_INVALID'
    }
    $receipt = $receiptText | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_INVALID'
  }
  if ($null -eq $receipt -or $receipt -is [System.Array] -or $null -eq $receipt.PSObject.Properties['schema'] -or $null -eq $receipt.PSObject.Properties['runId'] -or $null -eq $receipt.PSObject.Properties['ok'] -or $null -eq $receipt.PSObject.Properties['statusHash']) {
    return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_SCHEMA_INVALID'
  }
  if ([string]$receipt.schema -ne 'super-brain.verify-package-result.v1') {
    return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_SCHEMA_INVALID'
  }
  if ([string]$receipt.runId -ne $ExpectedRunId) {
    return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_RUN_MISMATCH'
  }
  if ($receipt.ok -isnot [bool]) {
    return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_OK_INVALID'
  }
  try {
    $expectedHash = Get-VerifyPackageResultHash $receipt
  } catch {
    return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_HASH_INVALID'
  }
  if ([string]$receipt.statusHash -notmatch '^[a-f0-9]{64}$' -or [string]$receipt.statusHash -ne $expectedHash) {
    return New-VerifyPackageReceiptCheck $false 'VERIFY_PACKAGE_RESULT_HASH_INVALID'
  }
  return New-VerifyPackageReceiptCheck $true '' $receipt $receiptText
}

function Resolve-VerifyPackageWorkerOutcome([object]$Outcome,[object]$ReceiptCheck,[string]$ExpectedRunId,[int]$TimeoutSeconds=0) {
  $receipt = if ($ReceiptCheck -and $ReceiptCheck.ok -eq $true) { $ReceiptCheck.receipt } else { $null }
  $entry = [ordered]@{
    ok = $false
    error = ''
    receipt = $receipt
    receiptText = if ($ReceiptCheck) { [string]$ReceiptCheck.receiptText } else { '' }
    runId = $ExpectedRunId
    exitCode = if ($Outcome) { [int]$Outcome.exitCode } else { -1 }
    timedOut = if ($Outcome) { [bool]$Outcome.timedOut } else { $false }
    timeoutSeconds = $TimeoutSeconds
    durationMs = if ($Outcome) { [int]$Outcome.durationMs } else { 0 }
    terminatedProcessIds = if ($Outcome) { @($Outcome.terminatedProcessIds) } else { @() }
  }
  if (-not $Outcome -or $Outcome.started -ne $true) {
    $entry.error = 'VERIFY_PACKAGE_START_FAILED'
    return [pscustomobject]$entry
  }
  if ($entry.timedOut) {
    $entry.error = 'VERIFY_PACKAGE_TIMEOUT'
    return [pscustomobject]$entry
  }
  if (-not $ReceiptCheck -or $ReceiptCheck.ok -ne $true) {
    $entry.error = if ($ReceiptCheck -and -not [string]::IsNullOrWhiteSpace([string]$ReceiptCheck.error)) { [string]$ReceiptCheck.error } else { 'VERIFY_PACKAGE_RESULT_MISSING' }
    return [pscustomobject]$entry
  }
  if ($entry.exitCode -ne 0) {
    $entry.error = if ($receipt.ok -eq $true) { 'VERIFY_PACKAGE_WORKER_EXIT_MISMATCH' } else { 'VERIFY_PACKAGE_WORKER_FAILED' }
    return [pscustomobject]$entry
  }
  if ($receipt.ok -ne $true) {
    $entry.error = 'VERIFY_PACKAGE_RESULT_NOT_OK'
    return [pscustomobject]$entry
  }
  $entry.ok = $true
  return [pscustomobject]$entry
}

function New-VerifyPackagePublicFailureResult([object]$Decision) {
  return [pscustomobject]@{
    schema = 'super-brain.verify-package-launch-result.v1'
    ok = $false
    error = [string]$Decision.error
    runId = [string]$Decision.runId
    exitCode = [int]$Decision.exitCode
    timedOut = [bool]$Decision.timedOut
    timeoutSeconds = [int]$Decision.timeoutSeconds
    durationMs = [int]$Decision.durationMs
    terminatedProcessIds = @($Decision.terminatedProcessIds)
  }
}

function Get-VerifyPackagePublicResult([object]$Decision) {
  if ($Decision -and $Decision.ok -eq $true -and $Decision.receipt -and $Decision.receipt.ok -eq $true) {
    return $Decision.receipt
  }
  if ($Decision -and $Decision.receipt -and $Decision.receipt.ok -eq $false) {
    return $Decision.receipt
  }
  return New-VerifyPackagePublicFailureResult $Decision
}
