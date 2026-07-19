$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\technology-decision.ps1'

function Write-TechnologyAnswers([string]$Path,[hashtable]$Answers) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Answers|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}

function Invoke-TechnologyDecision([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; text=$text; value=$(if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}) }
}

function New-CompleteAnswers {
  return [ordered]@{
    productUse='business_saas'
    projectStage='greenfield'
    coreCapabilities=@('auth_workflow','external_integrations')
    platform='web'
    teamStack='dotnet'
    deliveryPriority='longevity'
    scale='growth'
    latency='standard'
    dataShape='relational'
    aiWorkload='api_integration'
    security='enterprise'
    operations='containers'
    maintenance='standard_team'
    budget='balanced'
  }
}

Describe 'Structured technology decision engine' {
  It 'validates a complete cold catalog and normalized score model' {
    $result = Invoke-TechnologyDecision @('-Action','Validate','-Json')
    $result.exitCode | Should Be 0
    $result.value.validation.ok | Should Be $true
    $result.value.validation.questionCount | Should Be 14
    $result.value.validation.technologyCount -ge 30 | Should Be $true
    $result.value.validation.profileCount -ge 9 | Should Be $true
    $result.value.validation.dimensionCount | Should Be 10
    $result.value.validation.defaultWeightSum | Should Be 1
    $result.value.sideEffectFree | Should Be $true
  }

  It 'returns only bounded choice questions instead of requesting prose' {
    $result = Invoke-TechnologyDecision @('-Action','Questionnaire','-Json')
    $result.exitCode | Should Be 0
    @($result.value.questions).Count | Should Be 14
    @($result.value.questions | Where-Object { $_.required -ne $true }).Count | Should Be 0
    @($result.value.questions | Where-Object { @($_.options).Count -lt 2 }).Count | Should Be 0
    @($result.value.questions | Where-Object { $_.id -eq 'coreCapabilities' -and $_.multiple -eq $true }).Count | Should Be 1
    $result.value.nextAction | Should Match 'option IDs'
  }

  It 'refuses to infer missing requirements and returns the missing choices' {
    $path = Join-Path $TestDrive 'incomplete.json'
    Write-TechnologyAnswers $path ([ordered]@{ productUse='ai_product'; platform='web' })
    $result = Invoke-TechnologyDecision @('-Action','Recommend','-AnswersPath',$path,'-Json')
    $result.exitCode | Should Be 2
    $result.value.status | Should Be 'needs_answers'
    @($result.value.missingQuestions).Count -gt 5 | Should Be $true
    @($result.value.recommendations).Count | Should Be 0
  }

  It 'rejects unknown option IDs instead of silently normalizing them' {
    $answers = New-CompleteAnswers
    $answers.platform = 'imaginary_platform'
    $path = Join-Path $TestDrive 'invalid.json'
    Write-TechnologyAnswers $path $answers
    $result = Invoke-TechnologyDecision @('-Action','Recommend','-AnswersPath',$path,'-Json')
    $result.exitCode | Should Be 2
    @($result.value.invalidAnswers | Where-Object { $_.questionId -eq 'platform' -and $_.reason -eq 'unknown_option' }).Count | Should Be 1
  }

  It 'recommends an enterprise stack with auditable score contributions' {
    $path = Join-Path $TestDrive 'enterprise.json'
    Write-TechnologyAnswers $path (New-CompleteAnswers)
    $first = Invoke-TechnologyDecision @('-Action','Recommend','-AnswersPath',$path,'-TopK','3','-Json')
    $second = Invoke-TechnologyDecision @('-Action','Recommend','-AnswersPath',$path,'-TopK','3','-Json')
    $winner = $first.value.recommendations[0]

    $first.exitCode | Should Be 0
    $first.value.winnerId | Should Be 'dotnet-enterprise-modular'
    $second.value.winnerId | Should Be $first.value.winnerId
    $second.value.recommendations[0].score | Should Be $winner.score
    @($winner.dimensionContributions).Count | Should Be 10
    @($winner.requirementContributions).Count | Should Be 14
    @($winner.stackMap | Where-Object { $_.layer -eq 'frontend' }).Count | Should Be 1
    @($winner.stackMap | Where-Object { $_.layer -eq 'backend' }).Count | Should Be 1
    @($winner.stackMap | Where-Object { $_.layer -eq 'data' }).Count | Should Be 1
    $first.value.status | Should Be 'recommended_under_current_evidence'
    @($first.value.volatileFactsToVerify).Count -gt 5 | Should Be $true
  }

  It 'selects the AI-native profile for RAG and agent workloads' {
    $answers = [ordered]@{ productUse='ai_product';projectStage='greenfield';coreCapabilities=@('ai_agents','analytics_pipeline');platform='web';teamStack='python';deliveryPriority='speed';scale='growth';latency='standard';dataShape='vector_ai';aiWorkload='rag_agents';security='enterprise';operations='managed';maintenance='low_ops';budget='balanced' }
    $path = Join-Path $TestDrive 'ai.json'
    Write-TechnologyAnswers $path $answers
    $result = Invoke-TechnologyDecision @('-Action','Recommend','-AnswersPath',$path,'-Json')
    $result.exitCode | Should Be 0
    $result.value.winnerId | Should Be 'python-ai-native-platform'
    @($result.value.recommendations[0].stackMap | Where-Object { $_.layer -eq 'ai' }).Count | Should Be 1
    @($result.value.recommendations[0].stackMap | Where-Object { $_.layer -eq 'ai-data' }).Count | Should Be 1
  }

  It 'keeps hard realtime on-prem edge work out of incompatible profiles' {
    $answers = [ordered]@{ productUse='edge_iot';projectStage='greenfield';coreCapabilities=@('device_integration','ai_agents');platform='edge_device';teamStack='go_rust';deliveryPriority='longevity';scale='growth';latency='hard_realtime';dataShape='local_first';aiWorkload='self_hosted';security='on_prem';operations='on_prem';maintenance='platform_team';budget='invest' }
    $path = Join-Path $TestDrive 'edge.json'
    Write-TechnologyAnswers $path $answers
    $result = Invoke-TechnologyDecision @('-Action','Recommend','-AnswersPath',$path,'-TopK','3','-Json')
    $result.exitCode | Should Be 0
    $result.value.winnerId | Should Be 'local-first-desktop-edge'
    $result.value.recommendations[0].feasible | Should Be $true
    @($result.value.recommendations | Where-Object { $_.id -eq 'go-event-driven-services' -and $_.feasible -eq $false }).Count | Should Be 1
  }

  It 'filters the catalog by layer and query without writing state' {
    $result = Invoke-TechnologyDecision @('-Action','Catalog','-Layer','backend','-Query','dotnet','-Json')
    $result.exitCode | Should Be 0
    @($result.value.technologies).Count | Should Be 1
    $result.value.technologies[0].id | Should Be 'aspnet-core'
    $result.value.technologies[0].weightedScore -gt 0 | Should Be $true
    @($result.value.technologies[0].scoreContributions).Count | Should Be 10
    @($result.value.comparisonWeights).Count | Should Be 10
    $result.value.sideEffectFree | Should Be $true
  }
}
