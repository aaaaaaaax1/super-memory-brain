param(
  [string]$TestsPath = '',
  [switch]$Json
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($TestsPath)) {
  $TestsPath = Join-Path $Root 'tests\memory-recall-tests.json'
}
$Tests = Get-Content -LiteralPath $TestsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$allOk = $true
$caseResults = @()

foreach ($test in $Tests) {
  if (-not $Json) { Write-Host "TEST: $($test.question)" }
  $haystack = ''
  $missingSources = @()
  $missingNeedles = @()
  $matchedNeedles = @()
  foreach ($source in @($test.sources)) {
    $path = Join-Path $Root $source
    if (Test-Path $path) {
      $haystack += "`n" + (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
    } else {
      if (-not $Json) { Write-Host "  MISSING_SOURCE $source" }
      $missingSources += $source
      $allOk = $false
    }
  }
  foreach ($needle in @($test.mustContain)) {
    if ($haystack.Contains($needle)) {
      if (-not $Json) { Write-Host "  OK $needle" }
      $matchedNeedles += $needle
    } else {
      if (-not $Json) { Write-Host "  MISSING $needle" }
      $missingNeedles += $needle
      $allOk = $false
    }
  }
  $caseResults += [pscustomobject]@{
    question = $test.question
    ok = ($missingSources.Count -eq 0 -and $missingNeedles.Count -eq 0)
    sources = @($test.sources)
    matched = @($matchedNeedles)
    missing = @($missingNeedles)
    missingSources = @($missingSources)
  }
}

if ($Json) {
  [pscustomobject]@{
    ok = $allOk
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    packageRoot = $Root
    testsPath = $TestsPath
    total = $caseResults.Count
    passed = @($caseResults | Where-Object { $_.ok }).Count
    failed = @($caseResults | Where-Object { -not $_.ok }).Count
    cases = @($caseResults)
  } | ConvertTo-Json -Depth 8
} else {
  if ($allOk) { Write-Host 'RECALL_TESTS_OK' } else { Write-Host 'RECALL_TESTS_FAILED' }
}

if ($allOk) { exit 0 }
exit 1
