$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }

function Invoke-JsonScript([string]$Path,[string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>$null)
  if ($LASTEXITCODE -ne 0) { throw "Script failed: $Path exit=$LASTEXITCODE output=$($raw -join ' ')" }
  return (($raw -join "`n") | ConvertFrom-Json)
}

function Invoke-Hook([string]$Prompt) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\codex-user-prompt-hook.ps1') -TestPrompt $Prompt 2>$null)
  if ($LASTEXITCODE -ne 0) { throw "Hook failed for: $Prompt" }
  if (-not $raw) { return '' }
  return [string](($raw -join "`n") | ConvertFrom-Json).hookSpecificOutput.additionalContext
}

Describe 'Engineering behavior holdout' {
  It 'routes natural feature wording through product coherence before implementation' {
    $prompts = @(
      (U @(32473,35774,32622,39029,34917,19968,20010,23548,20986,20837,21475,65292,21035,21482,22622,25353,38062,65292,35201,30475,23427,22312,23436,25972,27969,31243,37324,26159,20160,20040,20316,29992)),
      (U @(24110,25105,25226,29616,26377,27169,22359,21644,26032,33021,21147,20018,36215,26469,65292,20808,35828,28165,20837,21475,12289,29366,24577,24402,23646,21644,32467,26524,21435,21521))
    )
    foreach ($prompt in $prompts) {
      $intent = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$prompt,'-Json')
      $plan = Invoke-JsonScript (Join-Path $root 'scripts\why-plan.ps1') @('-Goal',$prompt,'-Json')
      $intent.intent | Should Be 'add_or_optimize_feature'
      @($intent.dispatchHints) -contains 'product_coherence_gate' | Should Be $true
      $plan.collaborationGate.changeClass | Should Be 'workflow'
      $plan.collaborationGate.autonomyTier | Should Be 'align'
      @($plan.collaborationGate.productCoherenceChecks) -contains 'product role' | Should Be $true
      @($plan.collaborationGate.productCoherenceChecks) -contains 'existing entry-to-result flow' | Should Be $true
    }
  }

  It 'requires discussion before a structural feature mutation' {
    $prompt = U @(36825,20010,21151,33021,20250,25913,25968,25454,24211,32467,26500,21644,25509,21475,65292,20320,20808,21028,26029,24590,20040,25509,20837,20877,21160,25163)
    $intent = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$prompt,'-Json')
    $plan = Invoke-JsonScript (Join-Path $root 'scripts\why-plan.ps1') @('-Goal',$prompt,'-Json')

    $intent.intent | Should Be 'add_or_optimize_feature'
    $plan.collaborationGate.changeClass | Should Be 'structural'
    $plan.collaborationGate.autonomyTier | Should Be 'discuss'
    $plan.collaborationGate.decisionIfAmbiguous | Should Be 'Discuss before mutation.'
    @($plan.collaborationGate.stopConditions).Count | Should BeGreaterThan 0
  }

  It 'keeps unknown personal facts empty while retaining verified project state' {
    $unknownQueries = @(
      (U @(25105,20303,22312,21738,37324,65311)),
      (U @(25105,30340,29983,26085,26159,20160,20040,65311)),
      (U @(25105,26368,21916,27426,20160,20040,25968,25454,24211,65311)),
      (U @(25105,30340,30805,22763,35770,25991,26631,39064,26159,20160,20040,65311))
    )
    foreach ($query in $unknownQueries) {
      $raw = @(& python (Join-Path $root 'runtime\brain_cli.py') --package-root $root recall --query $query --top-k 3 --max-tokens 500)
      $json = ($raw -join "`n").Trim()
      $results = if ([string]::IsNullOrWhiteSpace($json)) { @() } else { @($json | ConvertFrom-Json | Where-Object { $null -ne $_ }) }
      @($results).Count | Should Be 0
    }
    $knownRaw = @(& python (Join-Path $root 'runtime\brain_cli.py') --package-root $root recall --query (U @(36229,32423,22823,33041,24403,21069,29256,26412,26159,22810,23569,65311)) --top-k 3 --max-tokens 500)
    $knownJson = ($knownRaw -join "`n").Trim()
    $known = if ([string]::IsNullOrWhiteSpace($knownJson)) { @() } else { @($knownJson | ConvertFrom-Json | Where-Object { $null -ne $_ }) }
    @($known).Count | Should BeGreaterThan 0
    $manifestVersion = [string](Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    (($known | ConvertTo-Json -Depth 8).Contains($manifestVersion)) | Should Be $true
  }

  It 'selects Playwright normally and browser-act only for explicit fallback' {
    $normal = Invoke-Hook (U @(25171,24320,32593,39029,26816,26597,26412,22320,39029,38754,26377,27809,26377,24067,23616,38169,20301))
    $playwright = Invoke-Hook (U @(29992,32,80,108,97,121,119,114,105,103,104,116,32,39564,35777,36825,20010,30331,24405,27969,31243))
    $fallback = Invoke-Hook (U @(80,108,97,121,119,114,105,103,104,116,32,20570,19981,20102,36825,20010,39564,35777,30721,65292,25913,29992,32,98,114,111,119,115,101,114,45,97,99,116))
    $explicit = Invoke-Hook (U @(35831,30452,25509,20351,29992,32,98,114,111,119,115,101,114,45,97,99,116,32,26816,26597,24050,30331,24405,27983,35272,22120,29366,24577))
    $period = Invoke-Hook 'Inspect the rendered invoice page in the browser.'

    $normal.Contains('BROWSER_ROUTE selected=playwright') | Should Be $true
    $normal.Contains('fallback=browser-act') | Should Be $true
    $normal.Contains('fallbackAllowed=false') | Should Be $true
    $normal.Contains('name=browser-act') | Should Be $false
    $playwright.Contains('BROWSER_ROUTE selected=playwright') | Should Be $true
    $playwright.Contains('name=playwright') | Should Be $true
    $fallback.Contains('BROWSER_ROUTE selected=browser-act') | Should Be $true
    $fallback.Contains('reason=playwright_unreliable') | Should Be $true
    $fallback.Contains('name=browser-act') | Should Be $true
    $explicit.Contains('BROWSER_ROUTE selected=browser-act') | Should Be $true
    $explicit.Contains('reason=user_requested') | Should Be $true
    $period.Contains('BROWSER_ROUTE selected=playwright') | Should Be $true
  }

  It 'generalizes feature flow and browser fallback wording' {
    $featurePrompt = U @(25226,30331,24405,24341,23548,20018,36827,29992,25143,27969,31243,65292,19981,33021,20570,25104,23396,31435,24377,31383,12290)
    $feature = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$featurePrompt,'-Json')
    $fallback = Invoke-Hook "Playwright cannot reliably finish this browser check; fall back to browser-act."
    $feature.intent | Should Be 'add_or_optimize_feature'
    @($feature.dispatchHints) -contains 'product_coherence_gate' | Should Be $true
    $fallback.Contains('BROWSER_ROUTE selected=browser-act') | Should Be $true
    $fallback.Contains('reason=playwright_unreliable') | Should Be $true
  }

  It 'shares product flow semantics between intent and collaboration planning' {
    $prompts = @(
      (U @(25226,24322,24120,37325,35797,33021,21147,23884,20837,20219,21153,25191,34892,27969,31243)),
      (U @(22312,32467,31639,27169,22359,22686,21152,21457,31080,30003,35831,20837,21475)),
      (U @(25226,23433,20840,30830,35748,32465,36827,36134,25143,27969,31243))
    )
    foreach ($prompt in $prompts) {
      $intent = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$prompt,'-Json')
      $plan = Invoke-JsonScript (Join-Path $root 'scripts\why-plan.ps1') @('-Goal',$prompt,'-Json')
      $intent.intent | Should Be 'add_or_optimize_feature'
      @($intent.dispatchHints) -contains 'product_coherence_gate' | Should Be $true
      $plan.collaborationGate.changeClass | Should Be 'workflow'
      $plan.collaborationGate.autonomyTier | Should Be 'align'
    }
  }

  It 'prioritizes structural and product-flow changes over incidental failure wording' {
    $prompts = @(
      (U @(23558,25968,25454,26657,39564,21151,33021,25509,20837,23548,20837,27969,31243,65292,20808,35828,26126,22833,36133,29366,24577,30001,35841,22788,29702)),
      (U @(26032,22686,36328,32452,32455,32455,20849,20139,20250,25913,21464,25968,25454,24211,27169,22411,21644,26435,38480,36793,30028)),
      (U @(31163,32447,32534,25913,36896,20250,24433,21709,26435,38480,12289,25968,25454,27169,22411,21644,38271,26399,32500,25252))
    )
    foreach ($prompt in $prompts) {
      $intent = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$prompt,'-Json')
      $plan = Invoke-JsonScript (Join-Path $root 'scripts\why-plan.ps1') @('-Goal',$prompt,'-Json')
      $intent.intent | Should Be 'add_or_optimize_feature'
      @($intent.dispatchHints) -contains 'product_coherence_gate' | Should Be $true
      $plan.collaborationGate.applicable | Should Be $true
    }
  }

  It 'recognizes implicit workflow attachment language without broad state-word triggering' {
    $prompts = @(
      (U @(35753,39118,25511,22797,26680,25509,36827,36864,27454,38142,36335,65292,20837,21475,12289,29366,24577,21644,32467,26524,39029,24517,39035,34900,25509,12290)),
      (U @(25226,21040,36135,30830,35748,24182,20837,21806,21518,27969,31243,65292,20445,30041,22833,36133,36820,22238,21644,21518,32493,21160,20316,12290)),
      (U @(25226,31080,25454,26680,39564,25509,20837,25910,27454,36335,24452,65292,36827,20837,20301,32622,21644,26368,32456,33853,21040,30340,39029,38754,35201,26126,30830,12290)),
      'Attach dispute checks to the refund path and preserve the failure return state.',
      'Fold delivery confirmation into the returns journey with a coherent outcome page.'
    )
    foreach ($prompt in $prompts) {
      $intent = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$prompt,'-Json')
      $plan = Invoke-JsonScript (Join-Path $root 'scripts\why-plan.ps1') @('-Goal',$prompt,'-Json')
      $intent.intent | Should Be 'add_or_optimize_feature'
      @($intent.dispatchHints) -contains 'product_coherence_gate' | Should Be $true
      $plan.collaborationGate.changeClass | Should Be 'workflow'
      $plan.collaborationGate.autonomyTier | Should Be 'align'
    }
    $negative = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text','Show the current state without changing the workflow.','-Json')
    $negative.intent | Should Not Be 'add_or_optimize_feature'
  }

  It 'routes structural rewrite and migration through product discussion before ORC' {
    $prompts = @(
      (U @(23558,26680,24515,24037,21333,27969,31243,25913,25104,36328,26381,21153,32534,25490,24182,22686,21152,20381,36182,65292,20808,35752,35770,32500,25252,36793,30028,12290)),
      'Rewrite the account data model and API contract across modules before connecting the flow.',
      'Migrate database ownership across services and redesign the model before implementation.'
    )
    foreach ($prompt in $prompts) {
      $intent = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$prompt,'-Json')
      $plan = Invoke-JsonScript (Join-Path $root 'scripts\why-plan.ps1') @('-Goal',$prompt,'-Json')
      $intent.intent | Should Be 'add_or_optimize_feature'
      @($intent.dispatchHints) -contains 'product_coherence_gate' | Should Be $true
      $plan.collaborationGate.changeClass | Should Be 'structural'
      $plan.collaborationGate.autonomyTier | Should Be 'discuss'
    }
  }

  It 'generalizes bounded workflow attachment and replacement semantics' {
    $workflowPrompts = @(
      (U @(25226,36864,36135,30331,24405,25509,21040,20179,20648,22788,29702,27969,31243,65292,22833,36133,21518,22238,21040,21407,33410,28857,12290)),
      (U @(35753,22797,26680,32467,26524,36827,20837,25253,38144,23457,25209,38142,65292,39539,22238,21518,36820,22238,21407,21333,25454,12290)),
      'Thread identity review into claim submission with rejected outcomes.',
      'Fold membership checks into service booking and preserve the recovery context.'
    )
    foreach ($prompt in $workflowPrompts) {
      $intent = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$prompt,'-Json')
      $plan = Invoke-JsonScript (Join-Path $root 'scripts\why-plan.ps1') @('-Goal',$prompt,'-Json')
      $intent.intent | Should Be 'add_or_optimize_feature'
      @($intent.dispatchHints) -contains 'product_coherence_gate' | Should Be $true
      $plan.collaborationGate.changeClass | Should Be 'workflow'
      $plan.collaborationGate.autonomyTier | Should Be 'align'
    }
    $structural = U @(25226,20107,20214,24635,32447,26367,25442,25104,26032,30340,36328,26381,20381,36182,65292,20808,35752,35770,21457,24067,21644,22238,28378,12290)
    $intent = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$structural,'-Json')
    $plan = Invoke-JsonScript (Join-Path $root 'scripts\why-plan.ps1') @('-Goal',$structural,'-Json')
    $intent.intent | Should Be 'add_or_optimize_feature'
    $plan.collaborationGate.changeClass | Should Be 'structural'
    $plan.collaborationGate.autonomyTier | Should Be 'discuss'
    $readOnlyPrompts = @(
      'Show the current process status without changing anything.',
      'Show the cross-service status without changing it.',
      (U @(36827,20837,39029,38754,26597,30475,24403,21069,29366,24577,12290)),
      (U @(35753,25105,30475,30475,25253,38144,23457,25209,38142,29366,24577,12290)),
      (U @(26597,30475,24403,21069,20381,36182,21015,34920,12290)),
      (U @(26174,31034,25903,20184,26435,38480,26550,26500,12290))
    )
    foreach ($prompt in $readOnlyPrompts) {
      $readOnlyIntent = Invoke-JsonScript (Join-Path $root 'scripts\intent-router.ps1') @('-Text',$prompt,'-Json')
      $readOnlyIntent.intent | Should Not Be 'add_or_optimize_feature'
    }
  }

  It 'abstains from unsupported autobiographical timeline and device facts' {
    $queries = @(
      (U @(25105,21738,19968,24180,25644,36807,23478,65311)),
      (U @(25105,29992,36807,30340,31532,19968,21488,25163,26426,26159,20160,20040,22411,21495,65311))
    )
    foreach ($query in $queries) {
      $raw = @(& python (Join-Path $root 'runtime\brain_cli.py') --package-root $root recall --query $query --top-k 3 --max-tokens 500)
      $json = ($raw -join "`n").Trim()
      $results = if ([string]::IsNullOrWhiteSpace($json)) { @() } else { @($json | ConvertFrom-Json | Where-Object { $null -ne $_ }) }
      @($results).Count | Should Be 0
    }
  }
}
