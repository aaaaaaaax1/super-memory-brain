Describe 'Super Memory Brain bounded Pester sandbox pool' {
  It 'runs a bounded Fast fixture in independent state roots' {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $fixtureRoot = Join-Path $TestDrive ('pester-parallel-fixture-' + [guid]::NewGuid().ToString('n'))
    $fixtureScripts = Join-Path $fixtureRoot 'scripts'
    $fixtureTests = Join-Path $fixtureRoot 'tests\powershell'
    $markerRoot = Join-Path $fixtureRoot 'markers'
    $fixtureRunner = Join-Path $fixtureScripts 'test-pester.ps1'
    $emittedReportPath = ''
    $fixtureNames = @('Ci.Tests.ps1','Common.Tests.ps1','Manifest.Tests.ps1','RouteRegression.Tests.ps1','TestPesterTiers.Tests.ps1')
    try {
      New-Item -ItemType Directory -Force -Path $fixtureScripts,$fixtureTests,$markerRoot | Out-Null
      Copy-Item -LiteralPath (Join-Path $root 'scripts\common.ps1') -Destination (Join-Path $fixtureScripts 'common.ps1') -Force
      Copy-Item -LiteralPath (Join-Path $root 'scripts\test-pester.ps1') -Destination $fixtureRunner -Force
      foreach ($fixtureName in @($fixtureNames)) {
        $markerPath = Join-Path $markerRoot ($fixtureName + '.txt')
        $escapedMarkerPath = $markerPath.Replace("'", "''")
        $escapedFixtureName = $fixtureName.Replace("'", "''")
        $fixtureText = @"
Describe 'parallel fixture $escapedFixtureName' {
  It 'uses only its assigned state root' {
    `$stateRoot = [string]`$env:SUPER_BRAIN_STATE_ROOT
    [string]::IsNullOrWhiteSpace(`$stateRoot) | Should Be `$false
    [string]::IsNullOrWhiteSpace([string]`$env:SUPER_BRAIN_ARCHIVE_ROOT) | Should Be `$false
    `$env:SUPER_BRAIN_ARCHIVE_ROOT.StartsWith(`$stateRoot, [System.StringComparison]::OrdinalIgnoreCase) | Should Be `$true
    [string]::IsNullOrWhiteSpace([string]`$env:SUPER_BRAIN_WORKSPACE_KEY) | Should Be `$true
    `$env:SUPER_BRAIN_LOCAL_SESSION_ID -like 'pester-*' | Should Be `$true
    `$insideMarker = Join-Path `$stateRoot 'fixture-marker.txt'
    [System.IO.File]::WriteAllText(`$insideMarker, '$escapedFixtureName')
    [System.IO.File]::WriteAllText('$escapedMarkerPath', `$stateRoot)
    Start-Sleep -Milliseconds 250
    Test-Path -LiteralPath `$insideMarker | Should Be `$true
  }
}
"@
        [System.IO.File]::WriteAllText((Join-Path $fixtureTests $fixtureName), $fixtureText, (New-Object System.Text.UTF8Encoding($false)))
      }

      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixtureRunner -Tier Fast -MaxParallelSuites 3 2>&1)
      $exitCode = $LASTEXITCODE
      $exitCode | Should Be 0
      $reportLines = @($raw | Where-Object { [string]$_ -match '^PESTER_OK .* report=' } | Select-Object -Last 1)
      $reportLines.Count | Should Be 1
      $emittedReportPath = [regex]::Match([string]$reportLines[0], 'report=(.+)$').Groups[1].Value.Trim()
      Test-Path -LiteralPath $emittedReportPath | Should Be $true
      $emittedReportPath -like (Join-Path ([System.IO.Path]::GetTempPath()) 'super-brain-pester-reports\last-pester-*') | Should Be $true
      $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $emittedReportPath | ConvertFrom-Json
      $report.ok | Should Be $true
      $report.parallelExecution | Should Be $true
      $report.reportPathExplicit | Should Be $false
      $report.maxParallelSuites | Should Be 3
      $report.observedMaxParallelSuites | Should Be 3
      $report.suiteCount | Should Be $fixtureNames.Count
      $report.total | Should Be $fixtureNames.Count
      $stateRoots = @($fixtureNames | ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $markerRoot ($_.ToString() + '.txt')) })
      @($stateRoots | Select-Object -Unique).Count | Should Be $fixtureNames.Count
      @($stateRoots | Where-Object { $_ -notlike '*suite-state-*' }).Count | Should Be 0
    } finally {
      if (-not [string]::IsNullOrWhiteSpace($emittedReportPath)) { Remove-Item -LiteralPath $emittedReportPath -Force -ErrorAction SilentlyContinue }
      Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
