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

  It 'keeps route metadata complete and bounded across the route map' {
    $path = Join-Path $Root 'route-map.json'
    $doc = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
    $classes = @('direct','memory','task','continuity','diagnostic')
    $tiers = @('none','memory_only','task','continuity_light','full_diagnostic')
    @($doc.routes).Count | Should BeGreaterThan 10
    foreach ($route in @($doc.routes)) {
      [string]$route.route | Should Not BeNullOrEmpty
      (@($classes) -contains [string]$route.routeClass) | Should Be $true
      (@($tiers) -contains [string]$route.activationTier) | Should Be $true
      $route.requiresTaskPointer.GetType().Name | Should Match 'Boolean'
      $route.requiresProjectProof.GetType().Name | Should Match 'Boolean'
      $route.requiresCapabilityRoute.GetType().Name | Should Match 'Boolean'
      (@($classes) -contains [string]$route.userVisibleState) | Should Be $true
    }
  }

  It 'projects metadata without changing legacy intent output' {
    $router = Join-Path $Root 'scripts\intent-router.ps1'
    $continuation = (& $router -Text 'continue' -Json -SkipCapabilityRoute) | ConvertFrom-Json
    $continuation.intent | Should Be 'continue'
    $continuation.routeClass | Should Be 'continuity'
    $continuation.activationTier | Should Be 'continuity_light'
    $continuation.requiresTaskPointer | Should Be $true
    $continuation.requiresProjectProof | Should Be $true
    $continuation.requiresCapabilityRoute | Should Be $false

    $direct = (& $router -Text 'hello' -Json -SkipCapabilityRoute) | ConvertFrom-Json
    $direct.intent | Should Be 'general_task'
    $direct.routeClass | Should Be 'direct'
    $direct.activationTier | Should Be 'none'
    $direct.requiresTaskPointer | Should Be $false
    $direct.requiresProjectProof | Should Be $false
    $direct.requiresCapabilityRoute | Should Be $false
  }
}
