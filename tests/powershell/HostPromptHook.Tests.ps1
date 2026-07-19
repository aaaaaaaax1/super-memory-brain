$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Hook = Join-Path $Root 'scripts\codex-user-prompt-hook.ps1'

Describe 'Codex user prompt hook' {
  BeforeEach {
    $script:PreviousHookStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $env:SUPER_BRAIN_STATE_ROOT = Join-Path $TestDrive 'hook-state'
  }

  AfterEach {
    if ($null -eq $script:PreviousHookStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $script:PreviousHookStateRoot }
  }

  It 'stays silent for a greeting' {
    $output = @(& $Hook -TestPrompt 'hello')
    @($output).Count | Should Be 0
  }

  It 'stays silent for generic agent, product G1, and human-brain mentions' {
    $whatIsAgent = (-join (@(20160,20040,26159) | ForEach-Object { [char]$_ })) + ' agent'
    $g1Model = (-join (@(36825,20010) | ForEach-Object { [char]$_ })) + ' G1 ' + (-join (@(22411,21495,24590,20040,26679) | ForEach-Object { [char]$_ }))
    $humanBrain = -join (@(25105,26368,36817,33041,23376,26377,28857,20081) | ForEach-Object { [char]$_ })
    foreach ($prompt in @($whatIsAgent,$g1Model,$humanBrain)) {
      $output = @(& $Hook -TestPrompt $prompt)
      @($output).Count | Should Be 0
    }
  }

  It 'emits the execution gate for a repair prompt' {
    $output = (& $Hook -TestPrompt 'fix this broken workflow' | ConvertFrom-Json)
    $context = [string]$output.hookSpecificOutput.additionalContext
    $context.Contains('HOST_PRETURN_GATE') | Should Be $true
    $context.Contains('checkpoint.created=true') | Should Be $true
  }

  It 'emits the product gate for natural integration and optimization wording' {
    foreach ($prompt in @('help connect image generation into the existing project','improve this module so it is faster')) {
      $output = (& $Hook -TestPrompt $prompt | ConvertFrom-Json)
      $context = [string]$output.hookSpecificOutput.additionalContext
      $context.Contains('HOST_PRETURN_GATE') | Should Be $true
    }
  }

  It 'injects the current canonical workflow record before the first Git response' {
    $gitPrompt = 'git' + (-join (@(24590,20040,20889) | ForEach-Object { [char]$_ }))
    $output = (& $Hook -TestPrompt $gitPrompt -TestWorkspace 'C:\fixtures\Atoapi' | ConvertFrom-Json)
    $context = [string]$output.hookSpecificOutput.additionalContext
    $context.Contains('WORKFLOW_PREFERENCE_HARD_GATE') | Should Be $true
    $context.Contains('decisionKey=git-ui-commit-response') | Should Be $true
    $context.Contains('CANONICAL_RECORD:') | Should Be $true
    $context.Contains('Summary, Description, and Commit button text') | Should Be $true
    $context.Contains('git add/git commit commands') | Should Be $true
    $context.Contains('apology text') | Should Be $true
  }

  It 'checks the cold skill pool before declaring a skill unavailable' {
    $uniquePrompt = 'Use skill unavailable-check-regression-7f3a9c2e'
    $output = (& $Hook -TestPrompt $uniquePrompt | ConvertFrom-Json)
    $context = [string]$output.hookSpecificOutput.additionalContext
    $context.Contains('skill-pool-router') | Should Be $true
    $context.Contains('no activation or restart') | Should Be $true

    . (Join-Path $Root 'scripts\common.ps1')
    $statePath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-codex-user-prompt-hook.json'
    $stateText = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    $state = $stateText | ConvertFrom-Json
    $state.rawPromptStored | Should Be $false
    $stateText.Contains($uniquePrompt) | Should Be $false
  }

  It 'captures strong user corrections without storing the raw prompt or auto-promoting memory' {
    $prompt = -join (@(19981,23545,65292,20320,29702,35299,38169,20102,65292,19981,26159,35753,20320,25913,37027,20010,39033,30446) | ForEach-Object { [char]$_ })
    $output = (& $Hook -TestPrompt $prompt | ConvertFrom-Json)
    $context = [string]$output.hookSpecificOutput.additionalContext
    $context.Contains('CORRECTION_FEEDBACK_GATE') | Should Be $true
    $context.Contains('reflection-promotion.ps1') | Should Be $true
    $context.Contains('do not store the raw prompt') | Should Be $true

    . (Join-Path $Root 'scripts\common.ps1')
    $statePath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-codex-user-prompt-hook.json'
    $stateText = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    $state = $stateText | ConvertFrom-Json
    $state.userCorrection | Should Be $true
    $state.correctionCandidate.status | Should Be 'pending_verification'
    $state.rawPromptStored | Should Be $false
    $stateText.Contains($prompt) | Should Be $false
  }

  It 'resolves the Smag typo to an exact current skill path' {
    $output = (& $Hook -TestPrompt 'is the samg skill available' | ConvertFrom-Json)
    $context = [string]$output.hookSpecificOutput.additionalContext
    $context.Contains('EXACT_SKILL_RESOLUTION') | Should Be $true
    $context.Contains('name=Smag') | Should Be $true
    $context.Contains('share-mini-imagegen\SKILL.md') | Should Be $true
    $context.Contains('available now') | Should Be $true
  }

  It 'routes exact Chinese names and unique cold capability phrases without activation' {
    function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
    $profile = Join-Path $TestDrive 'cold-keyword-profile'
    $coldRoot = Join-Path $profile '.codex-cold-skills'
    $freeName = U @(20813,36153,29983,22270)
    $knowledgeComic = U @(30693,35782,28459,30011)
    $freeFolder = Join-Path $coldRoot $freeName
    $comicFolder = Join-Path $coldRoot 'baoyu-comic'
    New-Item -ItemType Directory -Force -Path $freeFolder,$comicFolder | Out-Null

    $freeFile = Join-Path $freeFolder 'SKILL.md'
    $comicFile = Join-Path $comicFolder 'SKILL.md'
    [IO.File]::WriteAllText($freeFile,"---`nname: $freeName`ndescription: Agnes image generation.`n---`n# $freeName`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($comicFile,"---`nname: baoyu-comic`ndescription: Create educational comics. Use when user asks for `"$knowledgeComic`".`n---`n# baoyu-comic`n",[Text.UTF8Encoding]::new($false))
    $freeHash = (Get-FileHash -LiteralPath $freeFile -Algorithm SHA256).Hash
    $comicHash = (Get-FileHash -LiteralPath $comicFile -Algorithm SHA256).Hash
    $entries = @(
      [pscustomobject]@{folder=$freeName;name=$freeName;description='Agnes image generation.';skillFile=$freeFile;sha256=$freeHash}
      [pscustomobject]@{folder='baoyu-comic';name='baoyu-comic';description="Create educational comics. Use when user asks for `"$knowledgeComic`".";skillFile=$comicFile;sha256=$comicHash}
    )
    $index = [pscustomobject]@{schema='codex.skill-pool-index.v1';entries=$entries}
    [IO.File]::WriteAllText((Join-Path $coldRoot 'skill-pool-index.json'),($index|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $lookup = @(
      'codex.skill-name-index.v1'
      "cold`t$freeName`t$freeName`t$freeFile`t$freeHash"
      "cold`tbaoyu-comic`tbaoyu-comic`t$comicFile`t$comicHash"
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $coldRoot 'skill-name-index.tsv'),$lookup+"`n",[Text.UTF8Encoding]::new($false))

    $oldProfile = $env:USERPROFILE
    try {
      $env:USERPROFILE = $profile
      foreach($prompt in @($freeName,((U @(24110,25105))+$freeName))) {
        $output = (& $Hook -TestPrompt $prompt | ConvertFrom-Json)
        $context = [string]$output.hookSpecificOutput.additionalContext
        $context.Contains('EXACT_SKILL_RESOLUTION') | Should Be $true
        $context.Contains('EXACT_SKILL_BINDING') | Should Be $true
        $context.Contains('Do not substitute') | Should Be $true
        $context.Contains("name=$freeName") | Should Be $true
        $context.Contains($freeFile) | Should Be $true
      }
      . (Join-Path $Root 'scripts\common.ps1')
      $stateRoot = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
      $hookState = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stateRoot 'last-codex-user-prompt-hook.json') | ConvertFrom-Json
      $hookState.routeTier | Should Be 'T0'
      $metrics = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stateRoot 'last-codex-route-metrics.json') | ConvertFrom-Json
      $metrics.counts.T0 -gt 0 | Should Be $true
      $metrics.rawPromptStored | Should Be $false

      $capabilityPrompt = (U @(24110,25105,20570,19968,20010)) + $knowledgeComic
      $stopwatch = [Diagnostics.Stopwatch]::StartNew()
      $capabilityOutput = (& $Hook -TestPrompt $capabilityPrompt | ConvertFrom-Json)
      $stopwatch.Stop()
      $capabilityContext = [string]$capabilityOutput.hookSpecificOutput.additionalContext
      $capabilityContext.Contains('CAPABILITY_SKILL_RESOLUTION') | Should Be $true
      $capabilityContext.Contains('name=baoyu-comic') | Should Be $true
      $capabilityContext.Contains($comicFile) | Should Be $true
      ($stopwatch.Elapsed.TotalMilliseconds -lt 3000) | Should Be $true

      $aliasOutput = (& $Hook -TestPrompt 'please use baoyu comic' | ConvertFrom-Json)
      $aliasContext = [string]$aliasOutput.hookSpecificOutput.additionalContext
      $aliasContext.Contains('EXACT_SKILL_RESOLUTION') | Should Be $true
      $aliasContext.Contains('name=baoyu-comic') | Should Be $true

      $fallbackPrompt = (U @(24110,25105,32534,36753,19968,31687,25991,31456))
      $fallbackOutput = (& $Hook -TestPrompt $fallbackPrompt | ConvertFrom-Json)
      $fallbackContext = [string]$fallbackOutput.hookSpecificOutput.additionalContext
      $fallbackContext.Contains('COLD_SKILL_FALLBACK') | Should Be $true
      $fallbackContext.Contains('translate when needed') | Should Be $true
      ($fallbackContext.Length -lt 260) | Should Be $true
      $fallbackContext.Contains('skill-pool-index') | Should Be $false
      $fallbackContext.Contains($freeFile) | Should Be $false
      $fallbackContext.Contains($comicFile) | Should Be $false

      $unrelatedPrompt = U @(24110,25105,25972,29702,19968,19979,20250,35758,32426,35201)
      @(& $Hook -TestPrompt $unrelatedPrompt).Count | Should Be 0
    } finally {
      $env:USERPROFILE = $oldProfile
    }
  }

  It 'rejects ambiguous normalized skill aliases' {
    $profile = Join-Path $TestDrive 'ambiguous-alias-profile'
    $coldRoot = Join-Path $profile '.codex-cold-skills'
    $entries = @()
    foreach($folder in @('alpha-beta','alpha_beta')) {
      $skillRoot = Join-Path $coldRoot $folder
      New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
      $skillFile = Join-Path $skillRoot 'SKILL.md'
      [IO.File]::WriteAllText($skillFile,"---`nname: $folder`ndescription: Ambiguous alias fixture.`n---`n",[Text.UTF8Encoding]::new($false))
      $entries += [pscustomobject]@{folder=$folder;name=$folder;description='Ambiguous alias fixture.';skillFile=$skillFile;sha256=(Get-FileHash -LiteralPath $skillFile -Algorithm SHA256).Hash}
    }
    $index = [pscustomobject]@{schema='codex.skill-pool-index.v1';entries=$entries}
    [IO.File]::WriteAllText((Join-Path $coldRoot 'skill-pool-index.json'),($index|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $lookup = @('codex.skill-name-index.v1') + @($entries | ForEach-Object { "cold`t$($_.folder)`t$($_.name)`t$($_.skillFile)`t$($_.sha256)" })
    [IO.File]::WriteAllText((Join-Path $coldRoot 'skill-name-index.tsv'),($lookup -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    $oldProfile = $env:USERPROFILE
    try {
      $env:USERPROFILE = $profile
      @(& $Hook -TestPrompt 'alpha beta').Count | Should Be 0
    } finally {
      $env:USERPROFILE = $oldProfile
    }
  }

  It 'prefers the longest normalized alias over a shorter raw skill name' {
    $profile = Join-Path $TestDrive 'specific-alias-profile'
    $activeRoot = Join-Path $profile '.codex\skills\review'
    $coldRoot = Join-Path $profile '.codex-cold-skills'
    $coldSkillRoot = Join-Path $coldRoot 'chinese-code-review'
    New-Item -ItemType Directory -Force -Path $activeRoot,$coldSkillRoot | Out-Null
    $activeFile = Join-Path $activeRoot 'SKILL.md'
    $coldFile = Join-Path $coldSkillRoot 'SKILL.md'
    [IO.File]::WriteAllText($activeFile,"---`nname: review`ndescription: Generic review fixture.`n---`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($coldFile,"---`nname: chinese-code-review`ndescription: Specific review fixture.`n---`n",[Text.UTF8Encoding]::new($false))
    $activeHash = (Get-FileHash -LiteralPath $activeFile -Algorithm SHA256).Hash
    $coldHash = (Get-FileHash -LiteralPath $coldFile -Algorithm SHA256).Hash
    $index = [pscustomobject]@{schema='codex.skill-pool-index.v1';entries=@([pscustomobject]@{folder='chinese-code-review';name='chinese-code-review';description='Specific review fixture.';skillFile=$coldFile;sha256=$coldHash})}
    [IO.File]::WriteAllText((Join-Path $coldRoot 'skill-pool-index.json'),($index|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $lookup = @(
      'codex.skill-name-index.v1'
      "active`treview`treview`t$activeFile`t$activeHash"
      "cold`tchinese-code-review`tchinese-code-review`t$coldFile`t$coldHash"
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $coldRoot 'skill-name-index.tsv'),$lookup+"`n",[Text.UTF8Encoding]::new($false))
    $oldProfile = $env:USERPROFILE
    try {
      $env:USERPROFILE = $profile
      $output = (& $Hook -TestPrompt 'chinese code review' | ConvertFrom-Json)
      $context = [string]$output.hookSpecificOutput.additionalContext
      $context.Contains('EXACT_SKILL_RESOLUTION') | Should Be $true
      $context.Contains($coldFile) | Should Be $true
      $context.Contains($activeFile) | Should Be $false
    } finally {
      $env:USERPROFILE = $oldProfile
    }
  }

  It 'prefers an active exposure over the duplicate cold source' {
    function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
    $profile = Join-Path $TestDrive 'active-exposure-profile'
    $activeRoot = Join-Path $profile '.codex\skills'
    $coldRoot = Join-Path $profile '.codex-cold-skills'
    $freeName = U @(20813,36153,29983,22270)
    $coldSkill = Join-Path $coldRoot $freeName
    $activeSkill = Join-Path $activeRoot $freeName
    New-Item -ItemType Directory -Force -Path $activeRoot,$coldSkill | Out-Null
    $coldFile = Join-Path $coldSkill 'SKILL.md'
    [IO.File]::WriteAllText($coldFile,"---`nname: $freeName`ndescription: Agnes free image generation.`n---`n",[Text.UTF8Encoding]::new($false))
    New-Item -ItemType Junction -Path $activeSkill -Target $coldSkill | Out-Null
    $activeFile = Join-Path $activeSkill 'SKILL.md'
    $hash = (Get-FileHash -LiteralPath $coldFile -Algorithm SHA256).Hash
    $lookup = @(
      'codex.skill-name-index.v1'
      "active`t$freeName`t$freeName`t$activeFile`t$hash"
      "cold`t$freeName`t$freeName`t$coldFile`t$hash"
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $coldRoot 'skill-name-index.tsv'),$lookup+"`n",[Text.UTF8Encoding]::new($false))
    $oldProfile = $env:USERPROFILE
    try {
      $env:USERPROFILE = $profile
      $output = (& $Hook -TestPrompt $freeName | ConvertFrom-Json)
      $context = [string]$output.hookSpecificOutput.additionalContext
      $context.Contains('source=active') | Should Be $true
      $context.Contains($activeFile) | Should Be $true
      $context.Contains('EXACT_SKILL_BINDING') | Should Be $true
    } finally {
      $env:USERPROFILE = $oldProfile
    }
  }

  It 'shares route-critical signals with the intent router' {
    $hookText = Get-Content -Raw -Encoding UTF8 -LiteralPath $Hook
    $routerText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\intent-router.ps1')
    foreach ($text in @($hookText,$routerText)) {
      $text.Contains("routing-kernel.ps1") | Should Be $true
      $text.Contains('Get-SuperBrainRouteSignals') | Should Be $true
    }
  }

  It 'keeps browser routing aligned with the router and persists only the decision' {
    $stateRoot = Join-Path $TestDrive 'browser-route-state'
    $router = Join-Path $Root 'scripts\intent-router.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $routeMap = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'route-map.json') | ConvertFrom-Json
      @($routeMap.routes | ForEach-Object { [string]$_.route }) -contains 'browser_automation' | Should Be $true

      $cases = @(
        [pscustomobject]@{ prompt='Inspect the rendered invoice page in the browser.'; route='playwright'; reason='default' },
        [pscustomobject]@{ prompt='Playwright cannot reliably finish this browser check; fall back to browser-act.'; route='browser-act'; reason='playwright_unreliable' }
      )
      foreach ($case in $cases) {
        $routerResult = (& $router -Text $case.prompt -Json | ConvertFrom-Json)
        $hookResult = (& $Hook -TestPrompt $case.prompt | ConvertFrom-Json)
        $context = [string]$hookResult.hookSpecificOutput.additionalContext
        $statePath = Join-Path (Join-Path $stateRoot 'workspace') 'last-codex-user-prompt-hook.json'
        $stateText = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath
        $state = $stateText | ConvertFrom-Json

        $routerResult.intent | Should Be 'browser_automation'
        $routerResult.browserTaskSignal | Should Be $true
        $routerResult.browserRoute | Should Be $case.route
        $routerResult.browserRouteReason | Should Be $case.reason
        $context.Contains("BROWSER_ROUTE selected=$($case.route)") | Should Be $true
        $state.browserTaskSignal | Should Be $true
        $state.browserRoute | Should Be $case.route
        $state.browserRouteReason | Should Be $case.reason
        $state.rawPromptStored | Should Be $false
        $stateText.Contains($case.prompt) | Should Be $false
      }
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }

  It 'falls back to a live scan when a compact-index match is stale' {
    $profile = Join-Path $TestDrive 'stale-index-profile'
    $coldSkill = Join-Path $profile '.codex-cold-skills\stale-skill'
    New-Item -ItemType Directory -Force -Path $coldSkill | Out-Null
    [IO.File]::WriteAllText((Join-Path $coldSkill 'SKILL.md'),"---`nname: stale-skill`ndescription: Test stale index recovery.`n---`n",[Text.UTF8Encoding]::new($false))
    $lookup = Join-Path $profile '.codex-cold-skills\skill-name-index.tsv'
    $missing = Join-Path $profile '.codex-cold-skills\missing\SKILL.md'
    [IO.File]::WriteAllText($lookup,"codex.skill-name-index.v1`ncold`tstale-skill`tstale-skill`t$missing`tBADHASH`n",[Text.UTF8Encoding]::new($false))
    $oldProfile = $env:USERPROFILE
    try {
      $env:USERPROFILE = $profile
      $output = (& $Hook -TestPrompt 'use stale-skill' | ConvertFrom-Json)
      $context = [string]$output.hookSpecificOutput.additionalContext
      $context.Contains('EXACT_SKILL_RESOLUTION') | Should Be $true
      $context.Contains((Join-Path $coldSkill 'SKILL.md')) | Should Be $true
      $context.Contains($missing) | Should Be $false
    } finally {
      $env:USERPROFILE = $oldProfile
    }
  }

  It 'injects a branch-aware resume packet through the real stdin hook path' {
    $stateRoot = Join-Path $TestDrive 'stdin-execution-contract'
    $workspaceKey = 'ws-f11111111111111111111111'
    $sessionKey = 'sid-f111111111111111111111111'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      @(& $contract -Action Set -TaskId 'task-stdin-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'main-line' -FocusLabel 'Objective judge main line' -TopicKeys @('objective-judge') -NextAction 'run objective judge' -StateRoot $stateRoot -NoExit -Json) | Out-Null
      @(& $contract -Action Set -TaskId 'task-stdin-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -InstructionMode side_branch -FocusId 'bounded-unfinished' -FocusLabel 'Bounded unfinished line' -TopicKeys @('bounded-unfinished') -NextAction 'finish bounded side verification' -StateRoot $stateRoot -NoExit -Json) | Out-Null
      @(& $contract -Action ResumeParent -TaskId 'task-stdin-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -BranchStatus partial -StateRoot $stateRoot -NoExit -Json) | Out-Null
      @(& $contract -Action Set -TaskId 'task-stdin-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -InstructionMode side_branch -FocusId 'continuity-side' -FocusLabel 'Plan continuity side branch' -TopicKeys @('topic-affinity') -NextAction 'verify topic affinity' -StateRoot $stateRoot -NoExit -Json) | Out-Null

      $payload = ([pscustomobject]@{ session_id=$sessionKey; prompt='topic-affinity must remain attached to this branch' } | ConvertTo-Json -Compress)
      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $exitCode = $LASTEXITCODE
      $output = (($raw -join "`n") | ConvertFrom-Json)
      $context = [string]$output.hookSpecificOutput.additionalContext

      $exitCode | Should Be 0
      $context.Contains('EXECUTION_CONTRACT_RESUME_PACKET') | Should Be $true
      $context.Contains('mainLine=Objective judge main line[main-line]') | Should Be $true
      $context.Contains('currentLine=Plan continuity side branch[continuity-side]') | Should Be $true
      $context.Contains('suspended=Objective judge main line') | Should Be $true
      $context.Contains('unfinished=#3:Bounded unfinished line') | Should Be $true
      $context.Contains('messageAffinity=active') | Should Be $true
      $context.Contains('confidence=high') | Should Be $true
      $context.Contains('needsClarification=false') | Should Be $true
      $context.Contains('actionAuthorization=withheld') | Should Be $true
      $context.Contains('oldActionsOmitted=true') | Should Be $true
      $context.Contains('knownNextAction=verify topic affinity') | Should Be $false
      $context.Contains('authorizedNextAction=verify topic affinity') | Should Be $false
      $context.Contains('=>run objective judge') | Should Be $false
      $context.Contains('=>finish bounded side verification') | Should Be $false
      $context.Contains('verify topic affinity') | Should Be $false
      $context.Contains('priorityOrder=#1:Plan continuity side branch') | Should Be $true
      $context.StartsWith('EXECUTION_CONTRACT_PENDING: actionAuthorization=withheld') | Should Be $true
      $context.Contains('mutationGuard=classify-before-mutation') | Should Be $true
      $context.Contains('Do not execute or infer an older next action') | Should Be $true
      ($context.Length -le 1900) | Should Be $true

      $captured = @(& $contract -Action Get -TaskId 'task-stdin-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -StateRoot $stateRoot -NoExit -Json) -join "`n" | ConvertFrom-Json
      $captured.needsReconciliation | Should Be $true
      $captured.latestMessageClassification.topicAffinity | Should Be 'active'
      @($captured.unfinishedWorkLines) -contains 'bounded-unfinished' | Should Be $true
      $hookStateJson = Get-Content -LiteralPath (Join-Path $stateRoot 'workspace\last-codex-user-prompt-hook.json') -Raw -Encoding UTF8
      $hookStateJson.Contains('run objective judge') | Should Be $false
      $hookStateJson.Contains('finish bounded side verification') | Should Be $false
      $hookStateJson.Contains('verify topic affinity') | Should Be $false
      $hookStateJson.Contains('oldActionsOmitted') | Should Be $true
      $revisionBeforeInvalid = [int]$captured.revision

      $invalidRaw = @('{not-json' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE | Should Be 0
      @($invalidRaw).Count | Should Be 0
      $afterInvalid = @(& $contract -Action Get -TaskId 'task-stdin-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -StateRoot $stateRoot -NoExit -Json) -join "`n" | ConvertFrom-Json
      [int]$afterInvalid.revision | Should Be $revisionBeforeInvalid
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'emits a fail-closed guard for a foreign root session without persisting old actions' {
    $stateRoot = Join-Path $TestDrive 'stdin-foreign-session'
    $workspaceKey = 'ws-f12121212121212121212121'
    $taskId = 'task-stdin-foreign-session'
    $ownerSession = 'sid-a121212121212121212121212'
    $foreignSession = 'sid-b121212121212121212121212'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      @(& $contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $ownerSession -FocusId 'owner-line' -NextAction 'FOREIGN_HOOK_ACTION_SENTINEL' -AssistantCommitment 'FOREIGN_HOOK_COMMITMENT_SENTINEL' -StateRoot $stateRoot -NoExit -Json) | Out-Null
      $contextPath = Join-Path $stateRoot 'workspace\current-task-context.json'
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $contextPath) | Out-Null
      [IO.File]::WriteAllText($contextPath,([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceKey;status='active';stale=$false;expiresAt=(Get-Date).AddHours(2).ToString('o')}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
      $payload = ([pscustomobject]@{session_id=$foreignSession;prompt='continue the prior owner line'} | ConvertTo-Json -Compress)

      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE | Should Be 0
      $output = (($raw -join "`n") | ConvertFrom-Json)
      $context = [string]$output.hookSpecificOutput.additionalContext
      $context.StartsWith('EXECUTION_CONTRACT_OBSERVATION_GUARD: actionAuthorization=withheld') | Should Be $true
      $context.Contains('EXECUTION_CONTRACT_FOREIGN_CONTEXT_IGNORED') | Should Be $true
      $context.Contains('FOREIGN_HOOK_ACTION_SENTINEL') | Should Be $false
      $context.Contains('FOREIGN_HOOK_COMMITMENT_SENTINEL') | Should Be $false
      $persisted = Get-Content -LiteralPath (Join-Path $stateRoot 'workspace\last-codex-user-prompt-hook.json') -Raw -Encoding UTF8
      $persisted.Contains('FOREIGN_HOOK_ACTION_SENTINEL') | Should Be $false
      $persisted.Contains('FOREIGN_HOOK_COMMITMENT_SENTINEL') | Should Be $false
      $persisted.Contains('oldActionsOmitted') | Should Be $true

      $ordinaryPayload = ([pscustomobject]@{session_id=$foreignSession;prompt='build an unrelated local calculator feature'} | ConvertTo-Json -Compress)
      $ordinaryRaw = @($ordinaryPayload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE | Should Be 0
      $ordinaryOutput = (($ordinaryRaw -join "`n") | ConvertFrom-Json)
      $ordinaryContext = [string]$ordinaryOutput.hookSpecificOutput.additionalContext
      $ordinaryContext.Contains('EXECUTION_CONTRACT_OBSERVATION_GUARD') | Should Be $false
      $ordinaryContext.Contains('FOREIGN_HOOK_ACTION_SENTINEL') | Should Be $false
      $ordinaryContext.Contains('FOREIGN_HOOK_COMMITMENT_SENTINEL') | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'emits a critical guard when implicit task selection is ambiguous' {
    $stateRoot = Join-Path $TestDrive 'stdin-ambiguous-contracts'
    $workspaceKey = 'ws-f13131313131313131313131'
    $session = 'sid-a131313131313131313131313'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      @(& $contract -Action Set -TaskId 'task-hook-ambiguous-a' -WorkspaceKey $workspaceKey -SessionKey $session -FocusId 'line-a' -NextAction 'AMBIGUOUS_ACTION_A_MUST_NOT_LEAK' -StateRoot $stateRoot -NoExit -Json) | Out-Null
      @(& $contract -Action Set -TaskId 'task-hook-ambiguous-b' -WorkspaceKey $workspaceKey -SessionKey $session -FocusId 'line-b' -NextAction 'AMBIGUOUS_ACTION_B_MUST_NOT_LEAK' -StateRoot $stateRoot -NoExit -Json) | Out-Null
      $payload = ([pscustomobject]@{session_id=$session;prompt='continue the current task'} | ConvertTo-Json -Compress)
      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE | Should Be 0
      $context = [string](($raw -join "`n") | ConvertFrom-Json).hookSpecificOutput.additionalContext
      $context.StartsWith('EXECUTION_CONTRACT_OBSERVATION_GUARD: actionAuthorization=withheld') | Should Be $true
      $context.Contains('EXECUTION_CONTRACT_TASK_AMBIGUOUS') | Should Be $true
      $context.Contains('AMBIGUOUS_ACTION_A_MUST_NOT_LEAK') | Should Be $false
      $context.Contains('AMBIGUOUS_ACTION_B_MUST_NOT_LEAK') | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'emits a critical guard when prompt observation returns an execution-contract error' {
    $stateRoot = Join-Path $TestDrive 'stdin-contract-error'
    $workspaceKey = 'ws-f14141414141414141414141'
    $taskId = 'task-hook-contract-error'
    $session = 'sid-a141414141414141414141414'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $created = ((@(& $contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $session -FocusId 'error-line' -NextAction 'ERROR_ACTION_MUST_NOT_LEAK' -StateRoot $stateRoot -NoExit -Json) -join "`n") | ConvertFrom-Json)
      $contextPath = Join-Path $stateRoot 'workspace\current-task-context.json'
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $contextPath) | Out-Null
      [IO.File]::WriteAllText($contextPath,([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceKey;status='active'}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
      $broken = Get-Content -LiteralPath $created.path -Raw -Encoding UTF8 | ConvertFrom-Json
      $broken.revision = 'not-an-integer'
      [IO.File]::WriteAllText($created.path,($broken|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
      $payload = ([pscustomobject]@{session_id=$session;prompt='continue the current task'} | ConvertTo-Json -Compress)
      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE | Should Be 0
      $context = [string](($raw -join "`n") | ConvertFrom-Json).hookSpecificOutput.additionalContext
      $context.StartsWith('EXECUTION_CONTRACT_OBSERVATION_GUARD: actionAuthorization=withheld') | Should Be $true
      $context.Contains('EXECUTION_CONTRACT_ERROR') | Should Be $true
      $context.Contains('ERROR_ACTION_MUST_NOT_LEAK') | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'ignores real stdin subagent prompts without mutating the controller contract' {
    $stateRoot = Join-Path $TestDrive 'stdin-subagent-isolation'
    $workspaceKey = 'ws-f22222222222222222222222'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      @(& $contract -Action Set -TaskId 'task-subagent-hook' -WorkspaceKey $workspaceKey -SessionKey 'controller-session' -FocusId 'controller-line' -NextAction 'keep controller plan' -StateRoot $stateRoot -NoExit -Json) | Out-Null
      $before = @(& $contract -Action Get -TaskId 'task-subagent-hook' -WorkspaceKey $workspaceKey -SessionKey 'controller-session' -StateRoot $stateRoot -NoExit -Json) -join "`n" | ConvertFrom-Json
      $payload = ([pscustomobject]@{ session_id='controller-session'; turn_id='subagent-turn'; agent_id='review-agent'; agent_type='explorer'; prompt='audit the controller plan without changing it' } | ConvertTo-Json -Compress)

      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE | Should Be 0
      @($raw).Count | Should Be 0
      $after = @(& $contract -Action Get -TaskId 'task-subagent-hook' -WorkspaceKey $workspaceKey -SessionKey 'controller-session' -StateRoot $stateRoot -NoExit -Json) -join "`n" | ConvertFrom-Json
      [int]$after.revision | Should Be ([int]$before.revision)
      $after.latestUserInstruction | Should Be $before.latestUserInstruction
      $after.nextAction | Should Be 'keep controller plan'
      (Test-Path -LiteralPath (Join-Path $stateRoot 'workspace\last-codex-user-prompt-hook.json')) | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }
}
