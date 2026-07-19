$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'Route regression scaffold' {
  It 'has production route cases with no accepted baseline gaps' {
    $path = Join-Path $Root 'tests\route-regression-cases.json'
    Test-Path -LiteralPath $path | Should Be $true
    $doc = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
    @($doc.cases).Count | Should BeGreaterThan 10
    $doc.phase | Should Be 'phase6-strict-regression-cases'
    @($doc.cases | Where-Object { $_.knownBaselineGap -eq $true }).Count | Should Be 0
    @($doc.cases | Where-Object { $_.mustFixBeforePhase6 -eq $true }).Count | Should Be 0
  }

  It 'runs route regression in non-strict mode' {
    $script = Join-Path $Root 'scripts\route-regression.ps1'
    Test-Path -LiteralPath $script | Should Be $true
    $json = & $script -Json
    if ($LASTEXITCODE -ne 0) { throw "route-regression.ps1 failed in non-strict mode" }
    $result = $json | ConvertFrom-Json
    $result.ok | Should Be $true
    $result.strict | Should Be $false
  }

  It 'keeps strict mode green after Phase 6 gap fixes' {
    $script = Join-Path $Root 'scripts\route-regression.ps1'
    $json = & $script -Json -Strict
    $exitCode = $LASTEXITCODE
    $result = $json | ConvertFrom-Json
    $exitCode | Should Be 0
    $result.ok | Should Be $true
    $result.strict | Should Be $true
    $result.failed | Should Be 0
    $result.knownBaselineGapCount | Should Be 0
  }
}
