$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Hook = Join-Path $Root 'scripts\codex-user-prompt-hook.ps1'

function Get-HookTelemetryPath([string]$MemoryBase) {
  $workspace = Join-Path $MemoryBase 'workspace'
  $pointerPath = Join-Path $workspace 'last-codex-user-prompt-hook.json'
  $pointer = Get-Content -Raw -Encoding UTF8 -LiteralPath $pointerPath | ConvertFrom-Json
  $pointer.schema | Should Be 'super-brain.codex-user-prompt-hook-pointer.v1' | Out-Null
  $pointer.scope | Should Be 'session_workspace' | Out-Null
  return Join-Path $workspace (([string]$pointer.telemetryRelativePath) -replace '/','\')
}

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

  It 'keeps a greeting cold without mutating an active task intent receipt' {
    $stateRoot = Join-Path $TestDrive 'greeting-intent-cold-path'
    $workspaceKey = 'ws-h11111111111111111111111'
    $sessionKey = 'sid-h11111111111111111111111'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $intent = [pscustomobject]@{
        literalRequestDigest = 'editable notebook, but no direct database writes'
        resolvedOutcome = 'Users can edit notebook entries through governed commands.'
        productRole = 'local notebook UI backed by a governed command API'
        integrationObligations = @('local UI','governed command API')
        materialUnknowns = @()
        compatibilityGuards = @('no browser-side database access')
        preservedCapabilities = @('editable notebook')
        acceptanceCriteria = @('an edit produces a receipt')
        governedEquivalent = 'governed command editing through a local API'
        autonomyTier = 'align'
      } | ConvertTo-Json -Compress
      $created = @(& $contract -Action Set -TaskId 'task-greeting-cold' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -InstructionMode continue -FocusId 'notebook-ui' -NextAction 'implement governed notebook editing' -LatestUserInstruction 'add editable notebook without direct database writes' -IntentContractJson $intent -StateRoot $stateRoot -NoExit -Json) -join "`n" | ConvertFrom-Json
      $output = @(& $Hook -TestPrompt 'hello')
      $after = @(& $contract -Action Get -TaskId 'task-greeting-cold' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -StateRoot $stateRoot -NoExit -Json) -join "`n" | ConvertFrom-Json

      @($output).Count | Should Be 0
      [int]$after.revision | Should Be ([int]$created.revision)
      $after.intentResolutionReceipt.payloadHash | Should Be $created.intentResolutionReceipt.payloadHash
    } finally {
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
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
    $output = (& $Hook -TestPrompt $gitPrompt -TestWorkspace 'C:\fixtures\fixture-project-a' | ConvertFrom-Json)
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
    $context.Contains('auto-load at most one verified SKILL.md into this task') | Should Be $true

    . (Join-Path $Root 'scripts\common.ps1')
    $statePath = Get-HookTelemetryPath (Get-SuperBrainMemoryBaseRoot $Root)
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
    $statePath = Get-HookTelemetryPath (Get-SuperBrainMemoryBaseRoot $Root)
    $stateText = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    $state = $stateText | ConvertFrom-Json
    $state.userCorrection | Should Be $true
    $state.correctionCandidate.status | Should Be 'pending_verification'
    $state.rawPromptStored | Should Be $false
    $stateText.Contains($prompt) | Should Be $false
  }

  It 'classifies a Super Brain issue before repair without treating an old approved plan as a new approval' {
    . (Join-Path $Root 'scripts\\routing-kernel.ps1')
    $prompt = 'Why does Super Brain continue the approved main workline incorrectly?'
    $assessment = Get-SuperBrainIssueAssessment $prompt
    $output = (& $Hook -TestPrompt $prompt | ConvertFrom-Json)
    $context = [string]$output.hookSpecificOutput.additionalContext

    $assessment.detected | Should Be $true
    $assessment.problemNature | Should Be 'execution_continuity'
    $assessment.rootCauseState | Should Be 'evidence_required'
    $assessment.repairMode | Should Be 'diagnose_and_repair'
    $assessment.learningClass | Should Be 'execution_rule'
    $context.Contains('SUPER_BRAIN_ISSUE_RESPONSE_GATE') | Should Be $true
    $context.Contains('problemNature=execution_continuity') | Should Be $true
    $context.Contains('responseOrder=essence>evidence>repair>next') | Should Be $true
    $context.Contains('CANONICAL_PLAN_ADMISSION_GATE') | Should Be $false

    . (Join-Path $Root 'scripts\\common.ps1')
    $statePath = Get-HookTelemetryPath (Get-SuperBrainMemoryBaseRoot $Root)
    $stateText = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    $state = $stateText | ConvertFrom-Json
    $state.superBrainIssue.detected | Should Be $true
    $state.superBrainIssue.problemNature | Should Be 'execution_continuity'
    $state.rawPromptStored | Should Be $false
    $stateText.Contains($prompt) | Should Be $false
  }

  It 'keeps an explicit total-plan request in proposal mode and does not classify unrelated hook failures as Super Brain issues' {
    . (Join-Path $Root 'scripts\\routing-kernel.ps1')
    $planPrompt = 'Give me the total repair plan for this Super Brain issue; do not execute yet.'
    $planAssessment = Get-SuperBrainIssueAssessment $planPrompt
    $planOutput = (& $Hook -TestPrompt $planPrompt | ConvertFrom-Json)
    $planContext = [string]$planOutput.hookSpecificOutput.additionalContext
    $unrelatedOutput = (& $Hook -TestPrompt 'Why is this hook failing?' | ConvertFrom-Json)
    $unrelatedContext = [string]$unrelatedOutput.hookSpecificOutput.additionalContext

    $planAssessment.detected | Should Be $true
    $planAssessment.repairMode | Should Be 'plan_for_approval'
    $planContext.Contains('SUPER_BRAIN_ISSUE_RESPONSE_GATE') | Should Be $true
    $planContext.Contains('repairMode=plan_for_approval') | Should Be $true
    $unrelatedContext.Contains('SUPER_BRAIN_ISSUE_RESPONSE_GATE') | Should Be $false
  }

  It 'recognizes explicit correction-learning and collaborative-stance preferences without retaining the prompt text' {
    $prompt = ((-join (@(21487,20197,22810,35828) | ForEach-Object { [char]$_ })) + ' ' + (-join (@(36229,32423,22823,33041,26368,32570,33258,20027,24615,23398,20064,24615,21644,24615,26684,38656,35201,22521,20859) | ForEach-Object { [char]$_ })) + ' ' + (-join (@(20197,21518,29992,25143,32416,27491,21518,25226,39564,35777,30340,35268,21017,35760,20303,24182,33258,21160,23398,20064) | ForEach-Object { [char]$_ })))
    $output = (& $Hook -TestPrompt $prompt | ConvertFrom-Json)
    $context = [string]$output.hookSpecificOutput.additionalContext

    $context.Contains('USER_ADAPTATION_SIGNAL') | Should Be $true
    $context.Contains('response_detail:detailed') | Should Be $true
    $context.Contains('correction_learning:verify_then_apply') | Should Be $true
    $context.Contains('collaboration_stance:adaptive_partner') | Should Be $true

    . (Join-Path $Root 'scripts\common.ps1')
    $statePath = Get-HookTelemetryPath (Get-SuperBrainMemoryBaseRoot $Root)
    (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8).Contains($prompt) | Should Be $false
  }

  It 'resolves the Smag typo to an exact current skill path' {
    $output = (& $Hook -TestPrompt 'is the samg skill available' | ConvertFrom-Json)
    $context = [string]$output.hookSpecificOutput.additionalContext
    $context.Contains('EXACT_SKILL_RESOLUTION') | Should Be $true
    $context.Contains('selected=Smag') | Should Be $true
    $context.Contains('share-mini-imagegen\SKILL.md') | Should Be $true
    $context.Contains('SKILL_EXECUTION_BINDING: state=active_in_current_turn') | Should Be $true
  }

  It 'auto-loads exact Chinese names and unique cold capability phrases for the current task' {
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
        $context.Contains('SKILL_EXECUTION_BINDING: state=active_in_current_turn') | Should Be $true
        $context.Contains("selected=$freeName") | Should Be $true
        $context.Contains($freeFile) | Should Be $true
      }
      . (Join-Path $Root 'scripts\common.ps1')
      $stateRoot = Get-SuperBrainMemoryBaseRoot $Root
      $hookState = Get-Content -Raw -Encoding UTF8 -LiteralPath (Get-HookTelemetryPath $stateRoot) | ConvertFrom-Json
      $hookState.routeTier | Should Be 'T0'
      $metrics = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stateRoot 'workspace\last-codex-route-metrics.json') | ConvertFrom-Json
      $metrics.counts.T0 -gt 0 | Should Be $true
      $metrics.rawPromptStored | Should Be $false

      $capabilityPrompt = (U @(24110,25105,20570,19968,20010)) + $knowledgeComic
      $stopwatch = [Diagnostics.Stopwatch]::StartNew()
      $capabilityOutput = (& $Hook -TestPrompt $capabilityPrompt | ConvertFrom-Json)
      $stopwatch.Stop()
      $capabilityContext = [string]$capabilityOutput.hookSpecificOutput.additionalContext
      $capabilityContext.Contains('CAPABILITY_SKILL_RESOLUTION') | Should Be $true
      $capabilityContext.Contains('selected=baoyu-comic') | Should Be $true
      $capabilityContext.Contains($comicFile) | Should Be $true
      ($stopwatch.Elapsed.TotalMilliseconds -lt 3000) | Should Be $true

      $aliasOutput = (& $Hook -TestPrompt 'please use baoyu comic' | ConvertFrom-Json)
      $aliasContext = [string]$aliasOutput.hookSpecificOutput.additionalContext
      $aliasContext.Contains('EXACT_SKILL_RESOLUTION') | Should Be $true
      $aliasContext.Contains('selected=baoyu-comic') | Should Be $true

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

  It 'binds a high-confidence cold capability skill when task wording implies it' {
    function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
    $profile = Join-Path $TestDrive 'semantic-capability-profile'
    $coldRoot = Join-Path $profile '.codex-cold-skills'
    $skillFolder = Join-Path $coldRoot 'grilling'
    New-Item -ItemType Directory -Force -Path $skillFolder | Out-Null
    $skillFile = Join-Path $skillFolder 'SKILL.md'
    $description = 'Interview the user relentlessly about a plan or design. Use when the user wants to stress-test a plan before building, or uses any "grill" trigger phrases.'
    [IO.File]::WriteAllText($skillFile,"---`nname: grilling`ndescription: `"$description`"`n---`nAsk one focused question at a time and wait for the answer.",[Text.UTF8Encoding]::new($false))
    $hash = (Get-FileHash -LiteralPath $skillFile -Algorithm SHA256).Hash
    $index = [pscustomobject]@{schema='codex.skill-pool-index.v1';entries=@([pscustomobject]@{folder='grilling';name='grilling';description=$description;skillFile=$skillFile;sha256=$hash})}
    [IO.File]::WriteAllText((Join-Path $coldRoot 'skill-pool-index.json'),($index|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $oldProfile = $env:USERPROFILE
    try {
      $env:USERPROFILE = $profile
      $english = (& $Hook -TestPrompt 'Stress test this plan before building.' | ConvertFrom-Json)
      $englishContext = [string]$english.hookSpecificOutput.additionalContext
      $englishContext.Contains('CAPABILITY_SKILL_RESOLUTION') | Should Be $true
      $englishContext.Contains('SKILL_EXECUTION_BINDING: state=active_in_current_turn') | Should Be $true
      $englishContext.Contains('selected=grilling') | Should Be $true
      $englishContext.Contains($skillFile) | Should Be $true
      $englishContext.Contains('Ask one focused question at a time') | Should Be $true
      $englishContext.Contains('execution=grilling delegated=false') | Should Be $true
      $englishContext.Contains('bodyState=complete') | Should Be $true

      $chinesePrompt = (U @(20005,26684,25335,38382,36825,20010,26041,26696,65292,25214,20986,30450,28857,20877,23454,26045))
      $chinese = (& $Hook -TestPrompt $chinesePrompt | ConvertFrom-Json)
      $chineseContext = [string]$chinese.hookSpecificOutput.additionalContext
      $chineseContext.Contains('CAPABILITY_SKILL_RESOLUTION') | Should Be $true
      $chineseContext.Contains('SKILL_EXECUTION_BINDING: state=active_in_current_turn') | Should Be $true
      $chineseContext.Contains('selected=grilling') | Should Be $true
      $chineseContext.Contains('execution=grilling delegated=false') | Should Be $true

      $generic = (& $Hook -TestPrompt 'review this plan' | ConvertFrom-Json)
      ([string]$generic.hookSpecificOutput.additionalContext).Contains('execution=grilling') | Should Be $false
    } finally {
      $env:USERPROFILE = $oldProfile
    }
  }

  It 'auto-loads a selected cold wrapper through one verified execution delegate' {
    $profile = Join-Path $TestDrive 'delegated-capability-profile'
    $coldRoot = Join-Path $profile '.codex-cold-skills'
    $workflowFolder = Join-Path $coldRoot 'grilling'
    $wrapperFolder = Join-Path $coldRoot 'grill-me'
    New-Item -ItemType Directory -Force -Path $workflowFolder,$wrapperFolder | Out-Null
    $workflowFile = Join-Path $workflowFolder 'SKILL.md'
    $wrapperFile = Join-Path $wrapperFolder 'SKILL.md'
    [IO.File]::WriteAllText($workflowFile,"---`nname: grilling`ndescription: Stress-test a plan.`n---`nAsk one design question at a time and wait for the answer.",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($wrapperFile,"---`nname: grill-me`ndescription: A manual alias for plan grilling.`ndisable-model-invocation: true`ndelegates-to: grilling`n---`nRun the grilling workflow.",[Text.UTF8Encoding]::new($false))
    $oldProfile = $env:USERPROFILE
    try {
      $env:USERPROFILE = $profile
      $output = (& $Hook -TestPrompt 'grill me on this plan before implementation' | ConvertFrom-Json)
      $context = [string]$output.hookSpecificOutput.additionalContext
      $context.Contains('EXACT_SKILL_RESOLUTION') | Should Be $true
      $context.Contains('state=active_in_current_turn') | Should Be $true
      $context.Contains('requested=grill-me execution=grilling delegated=true') | Should Be $true
      $context.Contains('Ask one design question at a time') | Should Be $true
      $context.Contains('SKILL_EXECUTION_PACKET: bodyState=complete') | Should Be $true
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
      $context.Contains('SKILL_EXECUTION_BINDING: state=active_in_current_turn') | Should Be $true
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
        $statePath = Get-HookTelemetryPath $stateRoot
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
      $context.Contains('VISIBLE_RECEIPT') | Should Be $true
      $context.Contains('Completed history is never current.') | Should Be $true
      $context.Contains('Withheld means reconcile newest user instruction.') | Should Be $true
      $context.Contains('knownNextAction=verify topic affinity') | Should Be $false
      $context.Contains('authorizedNextAction=verify topic affinity') | Should Be $false
      $context.Contains('=>run objective judge') | Should Be $false
      $context.Contains('=>finish bounded side verification') | Should Be $false
      $context.Contains('verify topic affinity') | Should Be $false
      $context.Contains('priorityOrder=#1:Plan continuity side branch') | Should Be $true
      $context.StartsWith('EXECUTION_CONTRACT_PENDING: actionAuthorization=withheld') | Should Be $true
      $context.Contains('mutationGuard=classify-before-mutation') | Should Be $true
      $context.Contains('Do not execute or infer an older next action') | Should Be $true
      $context.Length | Should BeLessThan 3500

      $captured = @(& $contract -Action Get -TaskId 'task-stdin-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -StateRoot $stateRoot -NoExit -Json) -join "`n" | ConvertFrom-Json
      $captured.needsReconciliation | Should Be $true
      $captured.latestMessageClassification.topicAffinity | Should Be 'active'
      @($captured.unfinishedWorkLines) -contains 'bounded-unfinished' | Should Be $true
      $hookStateJson = Get-Content -LiteralPath (Get-HookTelemetryPath $stateRoot) -Raw -Encoding UTF8
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

  It 'preflights exact critical actions through the real hook without leaking stored actions' {
    $stateRoot = Join-Path $TestDrive 'stdin-critical-action-preflight'
    $workspaceKey = 'ws-f14141414141414141414141'
    $sessionKey = 'sid-f141414141414141414141414'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      foreach ($kind in @('commit','package','test','modify','sync')) {
        $taskId = 'task-hook-critical-'+$kind
        @(& $contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'action-line' -FocusLabel 'Critical action preflight' -TopicKeys @('action-preflight') -NextAction 'HOOK_ACTION_SENTINEL_MUST_NOT_LEAK' -Constraints @('keep task scope') -AcceptanceCriteria @('verify before action') -StateRoot $stateRoot -NoExit -Json) | Out-Null
        $payload = ([pscustomobject]@{session_id=$sessionKey;prompt=$kind}|ConvertTo-Json -Compress)
        $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
        $LASTEXITCODE | Should Be 0
        $output = (($raw -join "`n")|ConvertFrom-Json)
        $context = [string]$output.hookSpecificOutput.additionalContext
        $context.StartsWith('ACTION_DEPENDENCY_PREFLIGHT: actionAuthorization=withheld') | Should Be $true
        $context.Contains("actionKind=$kind") | Should Be $true
        $context.Contains('Current visible instruction wins') | Should Be $true
        $context.Contains('HOOK_ACTION_SENTINEL_MUST_NOT_LEAK') | Should Be $false
        ($context.Length -lt 900) | Should Be $true
        $captured = @(& $contract -Action Get -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $sessionKey -StateRoot $stateRoot -NoExit -Json) -join "`n" | ConvertFrom-Json
        $captured.needsReconciliation | Should Be $true
        $captured.latestMessageClassification.mode | Should Be 'action_preflight'
        @(& $contract -Action Clear -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $sessionKey -StateRoot $stateRoot -NoExit -Json) | Out-Null
      }
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'keeps a bare action direct when no current scoped task exists' {
    $stateRoot = Join-Path $TestDrive 'stdin-action-no-state'
    $workspaceKey = 'ws-f15151515151515151515151'
    $sessionKey = 'sid-f151515151515151515151515'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $payload = ([pscustomobject]@{session_id=$sessionKey;prompt='test'}|ConvertTo-Json -Compress)
      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE | Should Be 0
      @($raw).Count | Should Be 0
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'fails closed for scope-dependent bare actions when no current scoped task exists' {
    $stateRoot = Join-Path $TestDrive 'stdin-action-no-state-guard'
    $workspaceKey = 'ws-f16161616161616161616161'
    $sessionKey = 'sid-f161616161616161616161616'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      foreach ($kind in @('commit','package','modify','sync')) {
        $payload = ([pscustomobject]@{session_id=$sessionKey;prompt=$kind}|ConvertTo-Json -Compress)
        $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
        $LASTEXITCODE | Should Be 0
        $context = [string](($raw -join "`n") | ConvertFrom-Json).hookSpecificOutput.additionalContext
        $context.StartsWith('ACTION_DEPENDENCY_PREFLIGHT: actionAuthorization=withheld') | Should Be $true
        $context.Contains("actionKind=$kind") | Should Be $true
        $context.Contains('scope=unresolved') | Should Be $true
        $context.Contains('CURRENT_SCOPED_CONTRACT_MISSING') | Should Be $true
      }
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'fails closed for a bare test when only stale task state remains' {
    $stateRoot = Join-Path $TestDrive 'stdin-action-stale-state'
    $workspaceKey = 'ws-f17171717171717171717171'
    $sessionKey = 'sid-f171717171717171717171717'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      @(& $contract -Action Set -TaskId 'task-hook-stale-action' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'stale-line' -FocusLabel 'Stale action state' -NextAction 'STALE_ACTION_MUST_NOT_LEAK' -StateRoot $stateRoot -NoExit -Json) | Out-Null
      $indexPath = Join-Path $stateRoot ('workspace\runtime-state\execution-hot-index\'+$sessionKey+'--'+$workspaceKey+'.json')
      $index = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $index.entries[0].updatedAt = (Get-Date).AddDays(-8).ToString('o')
      [IO.File]::WriteAllText($indexPath,($index | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
      $payload = ([pscustomobject]@{session_id=$sessionKey;prompt='test'}|ConvertTo-Json -Compress)
      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE | Should Be 0
      $context = [string](($raw -join "`n") | ConvertFrom-Json).hookSpecificOutput.additionalContext
      $context.StartsWith('ACTION_DEPENDENCY_PREFLIGHT: actionAuthorization=withheld') | Should Be $true
      $context.Contains('actionKind=test') | Should Be $true
      $context.Contains('CURRENT_SCOPED_STATE_INELIGIBLE') | Should Be $true
      $context.Contains('STALE_ACTION_MUST_NOT_LEAK') | Should Be $false
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
      $persisted = Get-Content -LiteralPath (Get-HookTelemetryPath $stateRoot) -Raw -Encoding UTF8
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

  It 'shows the complete additive checklist and an auditable confirmation in a continue packet' {
    $stateRoot = Join-Path $TestDrive 'stdin-active-checklist'
    $workspaceKey = 'ws-active-checklist-hook-202607'
    $sessionKey = 'sid-active-checklist-hook-202607'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      @(& $contract -Action Set -TaskId 'task-active-checklist-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'main-line' -InstructionMode continue -LatestUserInstruction 'confirm A through I' -LastConfirmedSentence 'Confirmed plan A through I.' -LastConfirmedSource assistant_commitment -NextAction A -PendingSteps @('A','B','C','D','E','F','G','H','I') -StateRoot $stateRoot -NoExit -Json) | Out-Null

      $payload = ([pscustomobject]@{ session_id=$sessionKey; prompt='continue current plan' } | ConvertTo-Json -Compress)
      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $exitCode = $LASTEXITCODE
      $context = [string](($raw -join "`n") | ConvertFrom-Json).hookSpecificOutput.additionalContext

      $exitCode | Should Be 0
      $context.Contains('activeChecklist=1:pending:A') | Should Be $true
      $context.Contains('9:pending:I') | Should Be $true
      $context.Contains('checklistRule=additive-unless-explicit-replace') | Should Be $true
      $context.Contains('lastConfirmedSource=assistant_commitment') | Should Be $true
      $context.Contains('lastConfirmedSentence=Confirmed plan A through I.') | Should Be $true
      $context.Length | Should BeLessThan 3500
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey
    }
  }

  It 'emits canonical main before the active side work package within the soft hook budget' {
    $stateRoot = Join-Path $TestDrive 'stdin-canonical-plan'
    $workspaceKey = 'ws-canonical-hook-202607'
    $sessionKey = 'sid-canonical-hook-202607'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $rootRaw = @(& $contract -Action Set -TaskId 'task-canonical-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'main-line' -FocusLabel 'Approved main' -InstructionMode continue -LatestUserInstruction 'confirm A through C' -NextAction A -PendingSteps @('A','B','C') -EnableCanonicalPlan -RequireStructuralGuards -StateRoot $stateRoot -NoExit -Json)
      $rootContract = (($rootRaw | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
      $sideRaw = @(& $contract -Action Set -TaskId 'task-canonical-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'side-proof' -FocusLabel 'Side proof' -InstructionMode side_branch -LatestUserInstruction 'inspect side proof' -NextAction 'side one' -PendingSteps @('side one','side two') -ExpectedRevision ([int]$rootContract.revision) -ExpectedPlanFingerprint ([string]$rootContract.planReceipt.planFingerprint) -TransitionId 'open-hook-side' -StateRoot $stateRoot -NoExit -Json)
      $sideContract = (($sideRaw | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
      $sideContract.ok | Should Be $true

      $payload = ([pscustomobject]@{ session_id=$sessionKey; prompt='current plan and progress' } | ConvertTo-Json -Compress)
      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $context = [string](($raw -join "`n") | ConvertFrom-Json).hookSpecificOutput.additionalContext

      $LASTEXITCODE | Should Be 0
      $context.Contains('canonicalMain=') | Should Be $true
      $context.Contains('canonicalChecklist=1:pending:A | 2:pending:B | 3:pending:C') | Should Be $true
      $context.Contains('activeWorkPackage=Side proof[side-proof]:side_branch') | Should Be $true
      $context.Contains('workPackageChecklist=1:pending:side one | 2:pending:side two') | Should Be $true
      ($context.IndexOf('canonicalMain=') -lt $context.IndexOf('activeWorkPackage=')) | Should Be $true
      $context.Length | Should BeLessThan 4500
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'keeps a functional continuity packet intact past the soft hook target' {
    $stateRoot = Join-Path $TestDrive 'stdin-soft-budget-continuity'
    $workspaceKey = 'ws-soft-budget-hook-202607'
    $sessionKey = 'sid-soft-budget-hook-202607'
    $contract = Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $longSteps = @(1..10 | ForEach-Object { 'Phase ' + $_ + ' ' + ('x' * 220) })
      $rootRaw = @(& $contract -Action Set -TaskId 'task-soft-budget-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'main-line' -FocusLabel 'Approved main' -InstructionMode continue -LatestUserInstruction 'keep every approved phase visible' -LastConfirmedSentence ('Progress receipt ' + ('y' * 260)) -NextAction 'phase one' -PendingSteps $longSteps -EnableCanonicalPlan -RequireStructuralGuards -StateRoot $stateRoot -NoExit -Json)
      $rootContract = (($rootRaw | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
      $sideRaw = @(& $contract -Action Set -TaskId 'task-soft-budget-hook' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'side-proof' -FocusLabel 'Side proof' -InstructionMode side_branch -LatestUserInstruction 'inspect side proof' -NextAction 'side one' -PendingSteps @('side one','side two') -ExpectedRevision ([int]$rootContract.revision) -ExpectedPlanFingerprint ([string]$rootContract.planReceipt.planFingerprint) -TransitionId 'open-soft-budget-side' -StateRoot $stateRoot -NoExit -Json)
      (($sideRaw | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json).ok | Should Be $true

      $payload = ([pscustomobject]@{ session_id=$sessionKey; prompt='current plan and progress' } | ConvertTo-Json -Compress)
      $raw = @($payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $context = [string](($raw -join "`n") | ConvertFrom-Json).hookSpecificOutput.additionalContext
      $telemetryPath = Get-HookTelemetryPath $stateRoot
      $telemetry = Get-Content -LiteralPath $telemetryPath -Raw -Encoding UTF8 | ConvertFrom-Json

      $LASTEXITCODE | Should Be 0
      $context.Length | Should BeGreaterThan 1900
      $context.Contains('canonicalChecklistPreview=') | Should Be $true
      $context.Contains('canonicalFullPlanRequired=true') | Should Be $true
      $context.Contains('activeWorkPackage=Side proof[side-proof]:side_branch') | Should Be $true
      $context.Contains('latestInstructionAnchor=') | Should Be $true
      $telemetry.contextBudget.mode | Should Be 'soft'
      $telemetry.contextBudget.exceeded | Should Be $true
      $telemetry.contextBudget.terminalTruncation | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'requires canonical plan admission for a bare approval before any mutation can start' {
    $stateRoot = Join-Path $TestDrive 'stdin-canonical-admission'
    $workspaceKey = 'ws-canonical-admission-202607'
    $sessionKey = 'sid-canonical-admission-202607'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook -TestPrompt 'confirm and follow this plan' -TestSessionId $sessionKey 2>$null)
      $LASTEXITCODE | Should Be 0
      $output = (($raw -join "`n") | ConvertFrom-Json)
      $context = [string]$output.hookSpecificOutput.additionalContext

      $context.Contains('CANONICAL_PLAN_ADMISSION_GATE') | Should Be $true
      $context.Contains('recover the complete approved plan') | Should Be $true
      $context.Contains('autonomous-executor.ps1') | Should Be $true
      $context.Contains('do not reduce it to the newest detail') | Should Be $true
      $context.Contains('never invent a partial checklist') | Should Be $true
      $context.Length | Should BeLessThan 2500
      (Test-Path -LiteralPath (Join-Path $stateRoot 'workspace\runtime-state\execution-contracts') -PathType Container) | Should Be $false
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


  It 'creates a content-addressed task-choice receipt only from a real bound user turn' {
    $stateRoot=Join-Path $TestDrive 'stdin-adaptation-choice'
    $workspaceKey='ws-a1a1a1a1a1a1a1a1a1a1a1a1'
    $sessionKey='sid-a1a1a1a1a1a1a1a1a1a1a1a1'
    $taskId='task-adaptation-choice'
    $contract=Join-Path $Root 'scripts\execution-contract.ps1'
    $oldStateRoot=$env:SUPER_BRAIN_STATE_ROOT;$oldWorkspaceKey=$env:SUPER_BRAIN_WORKSPACE_KEY
    try{
      $env:SUPER_BRAIN_STATE_ROOT=$stateRoot;$env:SUPER_BRAIN_WORKSPACE_KEY=$workspaceKey
      $contractRaw=@(& $contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'code-review' -FocusLabel 'Code review workflow' -LatestUserInstruction 'approve the code review workflow' -AssistantCommitment 'complete the approved review' -NextAction 'run review' -CompletedSteps @('Forward review pass 1') -PendingSteps @('Forward review pass 2','Reverse audit 1') -EnableCanonicalPlan -StateRoot $stateRoot -NoExit -Json)
      $created=(($contractRaw-join"`n")|ConvertFrom-Json)
      $created.ok|Should Be $true
      $created.canonicalPlan.orderConfidence|Should Be 'verified'
      $prompt='For this task, use evidence first and report every phase transition.'
      $payload=([pscustomobject]@{session_id=$sessionKey;prompt=$prompt}|ConvertTo-Json -Compress)
      $raw=@($payload|& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      $LASTEXITCODE|Should Be 0
      $output=(($raw-join"`n")|ConvertFrom-Json)
      $telemetry=Get-Content -LiteralPath (Get-HookTelemetryPath $stateRoot) -Raw -Encoding UTF8|ConvertFrom-Json
      $telemetry.adaptationChoiceReceipt.errorCode|Should BeNullOrEmpty
      $telemetry.adaptationChoiceReceipt.ok|Should Be $true
      $telemetry.adaptationChoiceReceipt.mode|Should Be 'apply'
      $telemetry.adaptationChoiceReceipt.signalCount|Should Be 2
      ([string]$output.hookSpecificOutput.additionalContext).Contains('USER_ADAPTATION_CONFIRMATION_RECEIPT')|Should Be $true
      $receiptRoot=Join-Path $stateRoot 'workspace\runtime-state\user-confirmation-receipts'
      $receipts=@(Get-ChildItem -LiteralPath $receiptRoot -File -Filter '*.json')
      $receipts.Count|Should Be 1
      $receipt=Get-Content -LiteralPath $receipts[0].FullName -Raw -Encoding UTF8|ConvertFrom-Json
      $receipt.schema|Should Be 'super-brain.user-adaptation-confirmation-receipt.v2'
      $receipt.producer|Should Be 'codex_host_user_turn'
      $receipt.actor|Should Be 'real_user'
      $receipt.taskId|Should Be $taskId
      $receipt.taskInstanceId|Should Be $created.taskInstanceId
      $receipt.workspaceKey|Should Be $workspaceKey
      $receipt.ownerSessionKey|Should Be $sessionKey
      $receipt.selection.scope|Should Be 'workflow'
      $receipt.selection.workflow.key|Should Be 'code-review'
      $receipt.planBinding.originFingerprint|Should Be $created.canonicalPlan.originFingerprint
      @($receipt.selection.signals).Count|Should Be 2
      $receipt.rawPromptStored|Should Be $false
      (Get-Content -LiteralPath $receipts[0].FullName -Raw -Encoding UTF8).Contains($prompt)|Should Be $false

      $testOutput=& $Hook -TestPrompt $prompt -TestSessionId $sessionKey|ConvertFrom-Json
      $testTelemetry=Get-Content -LiteralPath (Get-HookTelemetryPath $stateRoot) -Raw -Encoding UTF8|ConvertFrom-Json
      $testTelemetry.adaptationChoiceReceipt.mode|Should Be 'test'
      @(Get-ChildItem -LiteralPath $receiptRoot -File -Filter '*.json').Count|Should Be 1
      $subagentPayload=([pscustomobject]@{session_id=$sessionKey;agent_id='review-agent';agent_type='explorer';prompt=$prompt}|ConvertTo-Json -Compress)
      $subagentRaw=@($subagentPayload|& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook 2>$null)
      @($subagentRaw).Count|Should Be 0
      @(Get-ChildItem -LiteralPath $receiptRoot -File -Filter '*.json').Count|Should Be 1
    }finally{
      if($null-eq$oldStateRoot){Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_STATE_ROOT=$oldStateRoot}
      if($null-eq$oldWorkspaceKey){Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_WORKSPACE_KEY=$oldWorkspaceKey}
    }
  }

  It 'requires an explicit risk floor before treating review counts as a protocol choice' {
    $stateRoot=Join-Path $TestDrive 'protocol-risk-floor'
    $oldStateRoot=$env:SUPER_BRAIN_STATE_ROOT
    try{
      $env:SUPER_BRAIN_STATE_ROOT=$stateRoot
      $null=& $Hook -TestPrompt 'For this task, use forward review 3 passes and reverse audit 2 passes.' -TestSessionId 'sid-riskfloor123456'
      $withoutRisk=Get-Content -LiteralPath (Get-HookTelemetryPath $stateRoot) -Raw -Encoding UTF8|ConvertFrom-Json
      $withoutRisk.taskPreferenceChoice.protocolRequested|Should Be $false
      $withoutRisk.adaptationChoiceReceipt|Should BeNullOrEmpty

      $null=& $Hook -TestPrompt 'For this task, use forward review 3 passes and reverse audit 2 passes; structural risk is the minimum boundary.' -TestSessionId 'sid-riskfloor123456'
      $withRisk=Get-Content -LiteralPath (Get-HookTelemetryPath $stateRoot) -Raw -Encoding UTF8|ConvertFrom-Json
      $withRisk.taskPreferenceChoice.protocolRequested|Should Be $true
      $withRisk.adaptationChoiceReceipt.mode|Should Be 'test'
      @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'workspace\runtime-state\user-confirmation-receipts') -File -ErrorAction SilentlyContinue).Count|Should Be 0
    }finally{
      if($null-eq$oldStateRoot){Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_STATE_ROOT=$oldStateRoot}
    }
  }
}
