$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\task-verification.ps1'
$checkpointWriterPath = Join-Path $root 'scripts\checkpoint-writer.ps1'
$commonPath = Join-Path $root 'scripts\common.ps1'

Describe 'Task verification learning receipt boundary' {
  It 'keeps the completion-bound verification artifact immutable and emits a separate queue receipt' {
    $text = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    ([regex]::Matches($text, 'Write-JsonUtf8NoBom \$verificationEvidencePath \$verification 12')).Count | Should Be 1
    $text.Contains("runtime-state\learning-verification-receipts") | Should Be $true
    $text.Contains('super-brain.learning-verification-receipt.v1') | Should Be $true
    $text.Contains('Record-LearningCandidateReceipt') | Should Be $true
    $text.Contains('-Action RecordVerification') | Should Be $true
  }

  It 'keeps learning links exact and free of raw verification payload fields' {
    $text = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    $text.Contains('[string]$LearningCandidateId') | Should Be $true
    $text.Contains('-VerificationReceiptPath ([string]$Receipt.path)') | Should Be $true
    $text.Contains('rawTranscriptStored=$false') | Should Be $true
    $text.Contains('-VerificationEvidenceRef $Summary') | Should Be $false
    $text.Contains('-VerificationEvidenceRef $Evidence') | Should Be $false
  }

  It 'propagates the current caller session through completion and exposes the atomic receipt' {
    $verification = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    $checkpointWriter = Get-Content -LiteralPath $checkpointWriterPath -Raw -Encoding UTF8
    $common = Get-Content -LiteralPath $commonPath -Raw -Encoding UTF8
    $verification.Contains('-CallerSessionKey (Get-SuperBrainLocalSessionKey)') | Should Be $true
    $checkpointWriter.Contains('-CallerSessionKey $CallerSessionKey') | Should Be $true
    $checkpointWriter.Contains('completionReceiptPath') | Should Be $true
    $checkpointWriter.Contains('completionReceiptHash') | Should Be $true
    $common.Contains('callerSessionKey = $resolvedCallerSessionKey') | Should Be $true
    $common.Contains('CallerSessionKey=$resolvedCallerSessionKey') | Should Be $true
  }
}
