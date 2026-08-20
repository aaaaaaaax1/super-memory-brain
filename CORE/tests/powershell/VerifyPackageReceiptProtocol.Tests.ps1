$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\common.ps1')
. (Join-Path $root 'scripts\internal\verify-package-receipt.ps1')

function New-TestVerifyPackageReceipt([string]$Path,[string]$RunId,[bool]$Ok=$true) {
  $receipt = [pscustomobject][ordered]@{
    schema = 'super-brain.verify-package-result.v1'
    runId = $RunId
    ok = $Ok
    checkedAt = '2026-08-06T00:00:00.0000000Z'
    packageRoot = 'test-package'
    version = 'test'
    durationMs = 1
    timeoutControlled = $true
    sourceTreeBinding = [pscustomobject]@{
      schema = 'super-brain.source-tree-binding.v1'
      treeAlgorithm = 'test'
      gitTreeHash = ('a' * 64)
      gitHeadTreeHash = ''
      fileCount = 1
    }
    results = @([pscustomobject]@{ name='test'; ok=$Ok; durationMs=1 })
    statusHash = ''
  }
  $receipt.statusHash = Get-VerifyPackageResultHash $receipt
  Write-JsonUtf8NoBom $Path $receipt 16
  return $receipt
}

function New-TestVerifyPackageOutcome([int]$ExitCode=0,[bool]$TimedOut=$false,[bool]$Started=$true) {
  return [pscustomobject]@{
    started = $Started
    exitCode = $ExitCode
    timedOut = $TimedOut
    durationMs = 7
    terminatedProcessIds = @()
  }
}

function Assert-TestVerifyPackageJsonExitAgreement([object]$Decision) {
  $public = Get-VerifyPackagePublicResult $Decision
  $expectedExitCode = if ($Decision.ok -eq $true) { 0 } else { 1 }
  ([bool]$public.ok -eq ($expectedExitCode -eq 0)) | Should Be $true
}

Describe 'Verify-package worker receipt protocol' {
  It 'clears a stale receipt before one worker run can begin' {
    $path = Join-Path $TestDrive 'stale-receipt.json'
    New-TestVerifyPackageReceipt $path 'vpr-stale-12345678' $true | Out-Null
    (Clear-VerifyPackageResultReceipt $path) | Should Be $true
    (Test-Path -LiteralPath $path) | Should Be $false
  }

  It 'fails closed when child exit 0 has no receipt' {
    $path = Join-Path $TestDrive 'missing-receipt.json'
    $check = Test-VerifyPackageResultReceipt $path 'vpr-missing-12345678'
    $decision = Resolve-VerifyPackageWorkerOutcome (New-TestVerifyPackageOutcome 0) $check 'vpr-missing-12345678' 30
    $check.error | Should Be 'VERIFY_PACKAGE_RESULT_MISSING'
    $decision.ok | Should Be $false
    $decision.error | Should Be 'VERIFY_PACKAGE_RESULT_MISSING'
    Assert-TestVerifyPackageJsonExitAgreement $decision
  }

  It 'fails closed when child exit 0 has a mismatched or corrupt receipt' {
    $mismatchPath = Join-Path $TestDrive 'mismatched-receipt.json'
    New-TestVerifyPackageReceipt $mismatchPath 'vpr-other-12345678' $true | Out-Null
    $mismatch = Test-VerifyPackageResultReceipt $mismatchPath 'vpr-expected-12345678'
    $mismatchDecision = Resolve-VerifyPackageWorkerOutcome (New-TestVerifyPackageOutcome 0) $mismatch 'vpr-expected-12345678' 30
    $mismatch.error | Should Be 'VERIFY_PACKAGE_RESULT_RUN_MISMATCH'
    $mismatchDecision.ok | Should Be $false
    Assert-TestVerifyPackageJsonExitAgreement $mismatchDecision

    $corruptPath = Join-Path $TestDrive 'corrupt-receipt.json'
    [IO.File]::WriteAllText($corruptPath,'{not-json}',[Text.UTF8Encoding]::new($false))
    $corrupt = Test-VerifyPackageResultReceipt $corruptPath 'vpr-corrupt-12345678'
    $corruptDecision = Resolve-VerifyPackageWorkerOutcome (New-TestVerifyPackageOutcome 0) $corrupt 'vpr-corrupt-12345678' 30
    $corrupt.error | Should Be 'VERIFY_PACKAGE_RESULT_INVALID'
    $corruptDecision.ok | Should Be $false
    Assert-TestVerifyPackageJsonExitAgreement $corruptDecision
  }

  It 'fails closed when child exit 0 has a status-hash mismatch or ok=false receipt' {
    $hashPath = Join-Path $TestDrive 'hash-receipt.json'
    $hashReceipt = New-TestVerifyPackageReceipt $hashPath 'vpr-hash-12345678' $true
    $hashReceipt.results[0].name = 'tampered'
    Write-JsonUtf8NoBom $hashPath $hashReceipt 16
    $hashCheck = Test-VerifyPackageResultReceipt $hashPath 'vpr-hash-12345678'
    $hashDecision = Resolve-VerifyPackageWorkerOutcome (New-TestVerifyPackageOutcome 0) $hashCheck 'vpr-hash-12345678' 30
    $hashCheck.error | Should Be 'VERIFY_PACKAGE_RESULT_HASH_INVALID'
    $hashDecision.ok | Should Be $false
    Assert-TestVerifyPackageJsonExitAgreement $hashDecision

    $failedPath = Join-Path $TestDrive 'failed-receipt.json'
    New-TestVerifyPackageReceipt $failedPath 'vpr-failed-12345678' $false | Out-Null
    $failedCheck = Test-VerifyPackageResultReceipt $failedPath 'vpr-failed-12345678'
    $failedDecision = Resolve-VerifyPackageWorkerOutcome (New-TestVerifyPackageOutcome 0) $failedCheck 'vpr-failed-12345678' 30
    $failedCheck.ok | Should Be $true
    $failedDecision.ok | Should Be $false
    $failedDecision.error | Should Be 'VERIFY_PACKAGE_RESULT_NOT_OK'
    (Get-VerifyPackagePublicResult $failedDecision).ok | Should Be $false
    Assert-TestVerifyPackageJsonExitAgreement $failedDecision
  }

  It 'never returns JSON ok=true when the worker exit is nonzero or timed out' {
    $path = Join-Path $TestDrive 'good-receipt.json'
    New-TestVerifyPackageReceipt $path 'vpr-nonzero-12345678' $true | Out-Null
    $check = Test-VerifyPackageResultReceipt $path 'vpr-nonzero-12345678'
    $nonzero = Resolve-VerifyPackageWorkerOutcome (New-TestVerifyPackageOutcome 1) $check 'vpr-nonzero-12345678' 30
    $nonzero.ok | Should Be $false
    $nonzero.error | Should Be 'VERIFY_PACKAGE_WORKER_EXIT_MISMATCH'
    (Get-VerifyPackagePublicResult $nonzero).schema | Should Be 'super-brain.verify-package-launch-result.v1'
    Assert-TestVerifyPackageJsonExitAgreement $nonzero

    $timeout = Resolve-VerifyPackageWorkerOutcome (New-TestVerifyPackageOutcome 0 $true) $check 'vpr-nonzero-12345678' 30
    $timeout.ok | Should Be $false
    $timeout.error | Should Be 'VERIFY_PACKAGE_TIMEOUT'
    Assert-TestVerifyPackageJsonExitAgreement $timeout
  }

  It 'accepts only a matching hashed ok=true receipt with child exit 0' {
    $path = Join-Path $TestDrive 'success-receipt.json'
    New-TestVerifyPackageReceipt $path 'vpr-success-12345678' $true | Out-Null
    $check = Test-VerifyPackageResultReceipt $path 'vpr-success-12345678'
    $decision = Resolve-VerifyPackageWorkerOutcome (New-TestVerifyPackageOutcome 0) $check 'vpr-success-12345678' 30
    $decision.ok | Should Be $true
    $decision.error | Should Be ''
    (Get-VerifyPackagePublicResult $decision).runId | Should Be 'vpr-success-12345678'
    Assert-TestVerifyPackageJsonExitAgreement $decision
  }

  It 'keeps ISO timestamp strings stable across PowerShell JSON readers' {
    $path = Join-Path $TestDrive 'cross-version-receipt.json'
    $written = New-TestVerifyPackageReceipt $path 'vpr-cross-version-12345678' $true
    $parsed = ConvertFrom-VerifyPackageJson (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
    $parsed.checkedAt.GetType().FullName | Should Be 'System.String'
    (Get-VerifyPackageResultHash $parsed) | Should Be ([string]$written.statusHash)
    (Test-VerifyPackageResultReceipt $path 'vpr-cross-version-12345678').ok | Should Be $true
  }

  It 'keeps the public verifier wired to the receipt protocol boundary' {
    $source = Get-Content -LiteralPath (Join-Path $root 'scripts\verify-package.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('internal\verify-package-receipt.ps1','Clear-VerifyPackageResultReceipt','Test-VerifyPackageResultReceipt','Resolve-VerifyPackageWorkerOutcome','Get-VerifyPackagePublicResult')) {
      $source.Contains($marker) | Should Be $true
    }
  }
}
