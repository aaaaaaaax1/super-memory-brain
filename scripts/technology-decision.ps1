param(
  [ValidateSet('Questionnaire','Recommend','Catalog','Validate')]
  [string]$Action = 'Questionnaire',
  [string]$AnswersJson = '',
  [string]$AnswersPath = '',
  [string]$WeightsJson = '',
  [string]$Layer = '',
  [string]$Query = '',
  [int]$TopK = 3,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $Root 'references\technology-catalog.json'
if (-not (Test-Path -LiteralPath $catalogPath)) { throw "TECHNOLOGY_CATALOG_MISSING path=$catalogPath" }
$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($TopK -lt 1) { $TopK = 1 }
if ($TopK -gt 9) { $TopK = 9 }

function Get-PropertyValue([object]$Object,[string]$Name) {
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

function Convert-ToArray([object]$Value) {
  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) { return @([string]$Value) }
  return @($Value | ForEach-Object { [string]$_ })
}

function Get-Question([string]$Id) {
  return @($catalog.questionnaire | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
}

function Get-Technology([string]$Id) {
  return @($catalog.technologies | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
}

function Get-OptionLabel([string]$QuestionId,[string]$OptionId) {
  $question = @(Get-Question $QuestionId)
  if ($question.Count -eq 0) { return $OptionId }
  $option = @($question[0].options | Where-Object { [string]$_.id -eq $OptionId } | Select-Object -First 1)
  if ($option.Count -eq 0) { return $OptionId }
  return [string]$option[0].label
}

function Add-Weight([hashtable]$Weights,[string]$Dimension,[double]$Delta) {
  if ($Weights.ContainsKey($Dimension)) { $Weights[$Dimension] = [Math]::Max(0.01, [double]$Weights[$Dimension] + $Delta) }
}

function Normalize-Weights([hashtable]$Weights) {
  $sum = [double](@($Weights.Values | Measure-Object -Sum).Sum)
  if ($sum -le 0) { throw 'TECHNOLOGY_WEIGHT_SUM_INVALID' }
  foreach ($key in @($Weights.Keys)) { $Weights[$key] = [Math]::Round(([double]$Weights[$key] / $sum), 6) }
  return $Weights
}

function Get-DerivedWeights([object]$Answers) {
  $weights = @{}
  foreach ($property in $catalog.defaultWeights.PSObject.Properties) { $weights[$property.Name] = [double]$property.Value }
  if (-not [string]::IsNullOrWhiteSpace($WeightsJson)) {
    $overrides = $WeightsJson | ConvertFrom-Json
    foreach ($property in $overrides.PSObject.Properties) {
      if (-not $weights.ContainsKey($property.Name)) { throw "UNKNOWN_WEIGHT dimension=$($property.Name)" }
      $weights[$property.Name] = [double]$property.Value
    }
    return Normalize-Weights $weights
  }

  switch ([string](Get-PropertyValue $Answers 'deliveryPriority')) {
    'speed' { Add-Weight $weights 'learningEase' 0.06; Add-Weight $weights 'operability' 0.03; Add-Weight $weights 'costEfficiency' 0.03 }
    'longevity' { Add-Weight $weights 'maturity' 0.04; Add-Weight $weights 'maintainability' 0.07; Add-Weight $weights 'security' 0.03 }
  }
  switch ([string](Get-PropertyValue $Answers 'scale')) {
    'high_scale' { Add-Weight $weights 'performance' 0.07; Add-Weight $weights 'operability' 0.05; Add-Weight $weights 'maturity' 0.02 }
    'prototype' { Add-Weight $weights 'learningEase' 0.04; Add-Weight $weights 'costEfficiency' 0.04 }
  }
  switch ([string](Get-PropertyValue $Answers 'latency')) {
    'realtime' { Add-Weight $weights 'performance' 0.06; Add-Weight $weights 'operability' 0.02 }
    'hard_realtime' { Add-Weight $weights 'performance' 0.10; Add-Weight $weights 'edgeFit' 0.07; Add-Weight $weights 'security' 0.02 }
  }
  switch ([string](Get-PropertyValue $Answers 'aiWorkload')) {
    'api_integration' { Add-Weight $weights 'aiNative' 0.06; Add-Weight $weights 'ecosystem' 0.02 }
    'rag_agents' { Add-Weight $weights 'aiNative' 0.11; Add-Weight $weights 'ecosystem' 0.03; Add-Weight $weights 'operability' 0.03 }
    'self_hosted' { Add-Weight $weights 'aiNative' 0.08; Add-Weight $weights 'security' 0.07; Add-Weight $weights 'performance' 0.04; Add-Weight $weights 'operability' 0.04 }
  }
  switch ([string](Get-PropertyValue $Answers 'security')) {
    'enterprise' { Add-Weight $weights 'security' 0.05; Add-Weight $weights 'maintainability' 0.02 }
    'regulated' { Add-Weight $weights 'security' 0.12; Add-Weight $weights 'maturity' 0.05; Add-Weight $weights 'operability' 0.04 }
    'on_prem' { Add-Weight $weights 'security' 0.09; Add-Weight $weights 'maintainability' 0.04; Add-Weight $weights 'operability' 0.04 }
  }
  switch ([string](Get-PropertyValue $Answers 'operations')) {
    'managed' { Add-Weight $weights 'operability' 0.07; Add-Weight $weights 'learningEase' 0.03; Add-Weight $weights 'costEfficiency' 0.02 }
    'serverless_edge' { Add-Weight $weights 'edgeFit' 0.10; Add-Weight $weights 'operability' 0.05; Add-Weight $weights 'costEfficiency' 0.03 }
    'containers' { Add-Weight $weights 'operability' 0.05; Add-Weight $weights 'performance' 0.03 }
    'on_prem' { Add-Weight $weights 'security' 0.07; Add-Weight $weights 'maintainability' 0.04; Add-Weight $weights 'operability' 0.05 }
  }
  switch ([string](Get-PropertyValue $Answers 'maintenance')) {
    'low_ops' { Add-Weight $weights 'operability' 0.08; Add-Weight $weights 'learningEase' 0.04; Add-Weight $weights 'maintainability' 0.03 }
    'platform_team' { Add-Weight $weights 'performance' 0.03; Add-Weight $weights 'security' 0.03; Add-Weight $weights 'maintainability' 0.04 }
  }
  if ([string](Get-PropertyValue $Answers 'budget') -eq 'lean') { Add-Weight $weights 'costEfficiency' 0.08; Add-Weight $weights 'learningEase' 0.03 }
  if ([string](Get-PropertyValue $Answers 'platform') -eq 'edge_device') { Add-Weight $weights 'edgeFit' 0.11; Add-Weight $weights 'performance' 0.04 }
  return Normalize-Weights $weights
}

function Get-CatalogValidation {
  $issues = New-Object System.Collections.ArrayList
  if ([string]$catalog.schema -ne 'super-brain.technology-catalog.v1') { [void]$issues.Add('invalid_schema') }
  $questionIds = @($catalog.questionnaire | ForEach-Object { [string]$_.id })
  if (@($questionIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) { [void]$issues.Add('duplicate_question_id') }
  foreach ($question in @($catalog.questionnaire)) {
    if (@($question.options).Count -lt 2) { [void]$issues.Add('question_has_fewer_than_two_options:' + [string]$question.id) }
    $optionIds = @($question.options | ForEach-Object { [string]$_.id })
    if (@($optionIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) { [void]$issues.Add('duplicate_option_id:' + [string]$question.id) }
  }
  $technologyIds = @($catalog.technologies | ForEach-Object { [string]$_.id })
  if (@($technologyIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) { [void]$issues.Add('duplicate_technology_id') }
  $profileIds = @($catalog.profiles | ForEach-Object { [string]$_.id })
  if (@($profileIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) { [void]$issues.Add('duplicate_profile_id') }
  $dimensions = @($catalog.defaultWeights.PSObject.Properties.Name)
  $weightSum = [double](@($catalog.defaultWeights.PSObject.Properties.Value | Measure-Object -Sum).Sum)
  if ([Math]::Abs($weightSum - 1.0) -gt 0.0001) { [void]$issues.Add('default_weights_do_not_sum_to_one') }
  foreach ($technology in @($catalog.technologies)) {
    foreach ($dimension in $dimensions) {
      $value = Get-PropertyValue $technology.scores $dimension
      if ($null -eq $value) { [void]$issues.Add('missing_technology_score:' + [string]$technology.id + ':' + $dimension) }
      elseif ([double]$value -lt 1 -or [double]$value -gt 5) { [void]$issues.Add('technology_score_out_of_range:' + [string]$technology.id + ':' + $dimension) }
    }
  }
  foreach ($profile in @($catalog.profiles)) {
    foreach ($component in @($profile.components)) { if ($technologyIds -notcontains [string]$component) { [void]$issues.Add('missing_component:' + [string]$profile.id + ':' + [string]$component) } }
    foreach ($dimension in $dimensions) {
      $value = Get-PropertyValue $profile.scores $dimension
      if ($null -eq $value) { [void]$issues.Add('missing_score:' + [string]$profile.id + ':' + $dimension) }
      elseif ([double]$value -lt 1 -or [double]$value -gt 5) { [void]$issues.Add('score_out_of_range:' + [string]$profile.id + ':' + $dimension) }
    }
    foreach ($fitProperty in $profile.fit.PSObject.Properties) { if ($questionIds -notcontains $fitProperty.Name) { [void]$issues.Add('unknown_fit_question:' + [string]$profile.id + ':' + $fitProperty.Name) } }
  }
  foreach ($requirement in $catalog.capabilityRequirements.PSObject.Properties) {
    $question = @(Get-Question 'coreCapabilities')
    if ($question.Count -eq 0 -or @($question[0].options.id) -notcontains $requirement.Name) { [void]$issues.Add('unknown_capability_requirement:' + $requirement.Name) }
    foreach ($component in @($requirement.Value.anyComponents)) { if ($technologyIds -notcontains [string]$component) { [void]$issues.Add('missing_capability_component:' + $requirement.Name + ':' + [string]$component) } }
  }
  return [pscustomobject]@{ ok=($issues.Count -eq 0); issueCount=$issues.Count; issues=@($issues); questionCount=@($catalog.questionnaire).Count; technologyCount=@($catalog.technologies).Count; profileCount=@($catalog.profiles).Count; dimensionCount=$dimensions.Count; defaultWeightSum=[Math]::Round($weightSum,6) }
}

function Get-ScoreCard([object]$Scores,[hashtable]$Weights) {
  $contributions = New-Object System.Collections.ArrayList
  $total = 0.0
  foreach ($dimension in @($Weights.Keys | Sort-Object)) {
    $score = [double](Get-PropertyValue $Scores $dimension)
    $contribution = ($score / 5.0) * [double]$Weights[$dimension] * 100.0
    $total += $contribution
    [void]$contributions.Add([pscustomobject]@{ dimension=$dimension; score=$score; weight=[Math]::Round([double]$Weights[$dimension],4); contribution=[Math]::Round($contribution,2) })
  }
  return [pscustomobject]@{ weightedScore=[Math]::Round($total,2); contributions=@($contributions | Sort-Object contribution -Descending) }
}

function Get-AnswerValidation([object]$Answers) {
  $missing = New-Object System.Collections.ArrayList
  $invalid = New-Object System.Collections.ArrayList
  foreach ($question in @($catalog.questionnaire)) {
    $value = Get-PropertyValue $Answers ([string]$question.id)
    $values = Convert-ToArray $value
    if ($question.required -eq $true -and $values.Count -eq 0) { [void]$missing.Add($question); continue }
    if ($question.multiple -ne $true -and $values.Count -gt 1) { [void]$invalid.Add([pscustomobject]@{ questionId=$question.id; reason='single_choice_required'; supplied=$values }); continue }
    $allowed = @($question.options | ForEach-Object { [string]$_.id })
    $unknown = @($values | Where-Object { $allowed -notcontains $_ })
    if ($unknown.Count -gt 0) { [void]$invalid.Add([pscustomobject]@{ questionId=$question.id; reason='unknown_option'; supplied=$unknown; allowed=$allowed }) }
  }
  return [pscustomobject]@{ ok=($missing.Count -eq 0 -and $invalid.Count -eq 0); missing=@($missing); invalid=@($invalid) }
}

function Get-CapabilityFit([object]$Profile,[string[]]$Capabilities) {
  if ($Capabilities.Count -eq 0) { return [pscustomobject]@{ score=100.0; details=@(); warnings=@() } }
  $details = New-Object System.Collections.ArrayList
  $warnings = New-Object System.Collections.ArrayList
  $total = 0.0
  foreach ($capability in $Capabilities) {
    $requirement = Get-PropertyValue $catalog.capabilityRequirements $capability
    if ($null -eq $requirement) { continue }
    $scoreChecks = New-Object System.Collections.ArrayList
    foreach ($minimum in $requirement.minimumScores.PSObject.Properties) {
      $actual = [double](Get-PropertyValue $Profile.scores $minimum.Name)
      [void]$scoreChecks.Add($actual -ge [double]$minimum.Value)
    }
    $scoreOk = (@($scoreChecks | Where-Object { $_ -ne $true }).Count -eq 0)
    $componentOk = (@($requirement.anyComponents | Where-Object { @($Profile.components) -contains [string]$_ }).Count -gt 0)
    $capabilityScore = if ($scoreOk -and $componentOk) { 100.0 } elseif ($scoreOk -or $componentOk) { 50.0 } else { 0.0 }
    $total += $capabilityScore
    if ($capabilityScore -lt 100) { [void]$warnings.Add("capability_gap:$capability") }
    [void]$details.Add([pscustomobject]@{ capability=$capability; label=Get-OptionLabel 'coreCapabilities' $capability; score=$capabilityScore; scoreThresholdsOk=$scoreOk; componentCoverageOk=$componentOk })
  }
  return [pscustomobject]@{ score=[Math]::Round(($total / [Math]::Max(1,$Capabilities.Count)),2); details=@($details); warnings=@($warnings) }
}

function Get-ProfileRecommendation([object]$Profile,[object]$Answers,[hashtable]$Weights) {
  $dimensionContributions = New-Object System.Collections.ArrayList
  $baseline = 0.0
  foreach ($dimension in @($Weights.Keys | Sort-Object)) {
    $score = [double](Get-PropertyValue $Profile.scores $dimension)
    $contribution = ($score / 5.0) * [double]$Weights[$dimension] * 100.0
    $baseline += $contribution
    [void]$dimensionContributions.Add([pscustomobject]@{ dimension=$dimension; score=$score; weight=[Math]::Round([double]$Weights[$dimension],4); contribution=[Math]::Round($contribution,2) })
  }

  $fitWeights = [ordered]@{ productUse=0.06; projectStage=0.06; coreCapabilities=0.11; platform=0.11; teamStack=0.08; deliveryPriority=0.05; scale=0.07; latency=0.08; dataShape=0.07; aiWorkload=0.09; security=0.09; operations=0.06; maintenance=0.04; budget=0.03 }
  $requirementContributions = New-Object System.Collections.ArrayList
  $warnings = New-Object System.Collections.ArrayList
  $hardWarnings = New-Object System.Collections.ArrayList
  $fitScore = 0.0
  $capabilities = Convert-ToArray (Get-PropertyValue $Answers 'coreCapabilities')
  $capabilityFit = Get-CapabilityFit $Profile $capabilities
  foreach ($warning in @($capabilityFit.warnings)) { [void]$warnings.Add($warning) }
  foreach ($entry in $fitWeights.GetEnumerator()) {
    $questionId = [string]$entry.Key
    $questionScore = 0.0
    $selected = Convert-ToArray (Get-PropertyValue $Answers $questionId)
    if ($questionId -eq 'coreCapabilities') {
      $questionScore = [double]$capabilityFit.score
    } elseif ($questionId -eq 'teamStack' -and $selected -contains 'no_preference') {
      $questionScore = 100.0
    } else {
      $supported = Convert-ToArray (Get-PropertyValue $Profile.fit $questionId)
      $matched = @($selected | Where-Object { $supported -contains $_ }).Count
      $questionScore = if ($selected.Count -eq 0) { 0.0 } else { 100.0 * $matched / $selected.Count }
    }
    $fitContribution = $questionScore * [double]$entry.Value
    $fitScore += $fitContribution
    if ($questionScore -lt 100) { [void]$warnings.Add("requirement_mismatch:$questionId") }
    if ($questionScore -lt 100 -and $questionId -in @('platform','latency','security','operations','aiWorkload')) { [void]$hardWarnings.Add("hard_constraint_mismatch:$questionId") }
    [void]$requirementContributions.Add([pscustomobject]@{ requirement=$questionId; selected=$selected; score=[Math]::Round($questionScore,2); weight=[double]$entry.Value; contribution=[Math]::Round($fitContribution,2) })
  }

  if ([string](Get-PropertyValue $Answers 'latency') -eq 'hard_realtime' -and [string]$Profile.architecture -notin @('native-client-with-modular-backend','local-first-sync-optional')) { [void]$hardWarnings.Add('hard_realtime_requires_target_hardware_validation') }
  if ([string](Get-PropertyValue $Answers 'aiWorkload') -eq 'self_hosted' -and @($Profile.components) -notcontains 'self-hosted-model-runtime') { [void]$hardWarnings.Add('self_hosted_model_runtime_missing') }
  if ([string](Get-PropertyValue $Answers 'security') -in @('regulated','on_prem') -and [string](Get-PropertyValue $Answers 'operations') -eq 'serverless_edge') { [void]$hardWarnings.Add('regulated_edge_residency_requires_live_proof') }

  $total = 0.42 * $baseline + 0.58 * $fitScore
  $componentRows = @($Profile.components | ForEach-Object { $technology = @(Get-Technology ([string]$_)); if ($technology.Count -gt 0) { $technology[0] } })
  $stackMap = @($componentRows | Group-Object layer | Sort-Object Name | ForEach-Object { [pscustomobject]@{ layer=$_.Name; choices=@($_.Group | ForEach-Object { [pscustomobject]@{ id=$_.id; name=$_.name; category=$_.category } }) } })
  return [pscustomobject]@{
    id=$Profile.id; name=$Profile.name; architecture=$Profile.architecture
    score=[Math]::Round($total,2); baselineScore=[Math]::Round($baseline,2); requirementFitScore=[Math]::Round($fitScore,2)
    feasible=(@($hardWarnings | Select-Object -Unique).Count -eq 0)
    dimensionContributions=@($dimensionContributions | Sort-Object contribution -Descending)
    requirementContributions=@($requirementContributions)
    capabilityFit=$capabilityFit; stackMap=$stackMap
    strengths=@($Profile.strengths); tradeoffs=@($Profile.tradeoffs)
    warnings=@(@($Profile.warnings) + @($warnings) | Select-Object -Unique)
    hardWarnings=@($hardWarnings | Select-Object -Unique)
  }
}

$validation = Get-CatalogValidation
if ($Action -eq 'Validate') {
  $result = [pscustomobject]@{ ok=$validation.ok; action=$Action; schema='super-brain.technology-decision.v1'; catalogPath=$catalogPath; catalogVersion=$catalog.catalogVersion; validation=$validation; sideEffectFree=$true }
  if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "TECHNOLOGY_DECISION_VALIDATE ok=$($result.ok) questions=$($validation.questionCount) technologies=$($validation.technologyCount) profiles=$($validation.profileCount) issues=$($validation.issueCount)" }
  if (-not $result.ok) { exit 1 }; exit 0
}

if (-not $validation.ok) { throw ('TECHNOLOGY_CATALOG_INVALID ' + ($validation.issues -join ',')) }

if ($Action -eq 'Questionnaire') {
  $example = [ordered]@{}
  foreach ($question in @($catalog.questionnaire)) { $example[[string]$question.id] = if ($question.multiple -eq $true) { @([string]$question.options[0].id) } else { [string]$question.options[0].id } }
  $result = [pscustomobject]@{ ok=$true; action=$Action; schema='super-brain.technology-decision.v1'; catalogVersion=$catalog.catalogVersion; questions=@($catalog.questionnaire); answerExample=[pscustomobject]$example; sideEffectFree=$true; nextAction='Return only the selected option IDs; no long-form requirement document is required.' }
  if ($Json) { $result | ConvertTo-Json -Depth 12 } else { foreach ($question in @($catalog.questionnaire)) { Write-Host "[$($question.id)] $($question.prompt)"; foreach ($option in @($question.options)) { Write-Host "  $($option.id): $($option.label)" } } }
  exit 0
}

if ($Action -eq 'Catalog') {
  $queryText = $Query.Trim().ToLowerInvariant()
  $catalogWeights = Get-DerivedWeights $null
  $technologies = @($catalog.technologies | Where-Object {
    $layerOk = [string]::IsNullOrWhiteSpace($Layer) -or [string]$_.layer -eq $Layer
    $haystack = (([string]$_.id) + ' ' + ([string]$_.name) + ' ' + ([string]$_.category) + ' ' + (@($_.tags) -join ' ')).ToLowerInvariant()
    $queryOk = [string]::IsNullOrWhiteSpace($queryText) -or $haystack.Contains($queryText)
    $layerOk -and $queryOk
  } | ForEach-Object {
    $scoreCard = Get-ScoreCard $_.scores $catalogWeights
    [pscustomobject]@{ id=$_.id; name=$_.name; layer=$_.layer; category=$_.category; tags=@($_.tags); scores=$_.scores; weightedScore=$scoreCard.weightedScore; scoreContributions=$scoreCard.contributions }
  } | Sort-Object @{Expression='weightedScore';Descending=$true}, id)
  $profiles = @($catalog.profiles | Where-Object {
    $haystack = (([string]$_.id) + ' ' + ([string]$_.name) + ' ' + ([string]$_.architecture) + ' ' + (@($_.components) -join ' ')).ToLowerInvariant()
    [string]::IsNullOrWhiteSpace($queryText) -or $haystack.Contains($queryText)
  })
  $result = [pscustomobject]@{ ok=$true; action=$Action; schema='super-brain.technology-decision.v1'; query=$Query; layer=$Layer; technologies=$technologies; profiles=$profiles; comparisonWeights=@($catalogWeights.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{dimension=$_;weight=[Math]::Round([double]$catalogWeights[$_],4)} }); scoreScale=$catalog.scoreScale; volatileFactsToVerify=@($catalog.volatileFactsToVerify); sideEffectFree=$true }
  if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "TECHNOLOGY_CATALOG technologies=$($technologies.Count) profiles=$($profiles.Count) layer=$Layer query=$Query" }
  exit 0
}

if (-not [string]::IsNullOrWhiteSpace($AnswersPath)) {
  $resolvedAnswersPath = [IO.Path]::GetFullPath($AnswersPath)
  if (-not (Test-Path -LiteralPath $resolvedAnswersPath -PathType Leaf)) { throw "ANSWERS_PATH_NOT_FOUND path=$resolvedAnswersPath" }
  $AnswersJson = Get-Content -LiteralPath $resolvedAnswersPath -Raw -Encoding UTF8
}
if ([string]::IsNullOrWhiteSpace($AnswersJson)) { throw 'ANSWERS_REQUIRED: run -Action Questionnaire, then use -AnswersJson or -AnswersPath with selected option IDs.' }
$answers = $AnswersJson | ConvertFrom-Json
$answerValidation = Get-AnswerValidation $answers
if (-not $answerValidation.ok) {
  $result = [pscustomobject]@{ ok=$false; action=$Action; status='needs_answers'; schema='super-brain.technology-decision.v1'; missingQuestions=@($answerValidation.missing); invalidAnswers=@($answerValidation.invalid); recommendations=@(); sideEffectFree=$true; nextAction='Answer only the listed choices; do not write a long requirement document.' }
  if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "TECHNOLOGY_DECISION_NEEDS_ANSWERS missing=$(@($answerValidation.missing).Count) invalid=$(@($answerValidation.invalid).Count)" }
  exit 2
}

$weights = Get-DerivedWeights $answers
$recommendations = @($catalog.profiles | ForEach-Object { Get-ProfileRecommendation $_ $answers $weights } | Sort-Object @{Expression='feasible';Descending=$true}, @{Expression='score';Descending=$true}, id | Select-Object -First $TopK)
$winner = if ($recommendations.Count -gt 0) { $recommendations[0] } else { $null }
$runnerUp = if ($recommendations.Count -gt 1) { $recommendations[1] } else { $null }
$margin = if ($winner -and $runnerUp) { [Math]::Round([double]$winner.score - [double]$runnerUp.score,2) } else { 0.0 }
$confidence = if (-not $winner -or $winner.feasible -ne $true) { 'low' } elseif ($margin -ge 8 -and @($winner.warnings).Count -le 2) { 'high' } elseif ($margin -ge 3) { 'medium' } else { 'low' }
$selectedCapabilities = Convert-ToArray (Get-PropertyValue $answers 'coreCapabilities')
$functionalBreakdown = @($selectedCapabilities | ForEach-Object { [pscustomobject]@{ id=$_; purpose=Get-OptionLabel 'coreCapabilities' $_ } })
$weightRows = @($weights.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ dimension=$_; weight=[Math]::Round([double]$weights[$_],4) } })
$result = [pscustomobject]@{
  ok=$true; action=$Action; status='recommended_under_current_evidence'; schema='super-brain.technology-decision.v1'
  catalogVersion=$catalog.catalogVersion; catalogAsOf=$catalog.asOf; answers=$answers; functionalBreakdown=$functionalBreakdown; weights=$weightRows
  recommendations=$recommendations; winnerId=if($winner){$winner.id}else{''}; winnerMargin=$margin; confidence=$confidence
  decisionBoundary='Catalog scores are expert priors. The result is not universally optimal and becomes commit-ready only after volatile facts and critical warnings are verified for the target environment.'
  volatileFactsToVerify=@($catalog.volatileFactsToVerify)
  nextAction='Verify current versions, pricing, regions, licenses, compliance, target benchmarks, and a timeboxed team spike; then record the chosen architecture through engineering-decision-gate.ps1.'
  sideEffectFree=$true
}
if ($Json) { $result | ConvertTo-Json -Depth 16 } else { Write-Host "TECHNOLOGY_DECISION winner=$($result.winnerId) score=$($winner.score) confidence=$confidence margin=$margin status=$($result.status)" }
exit 0
