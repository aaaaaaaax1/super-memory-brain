[CmdletBinding()]
param(
  [Parameter(Position=0,ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [string]$Intent = '',
  [int]$TopK = 4,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$inputText = (($Text -join ' ').Trim())
$normalized = if ([string]::IsNullOrWhiteSpace($inputText)) { '' } else { $inputText.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant() }
$compact = $normalized -replace '[\s\p{P}\p{S}]', ''

function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
$zhDiagnose = U @(35786,26029)
$zhDebug = U @(35843,35797)
$zhError = U @(25253,38169)
$zhFailed = U @(22833,36133)
$zhCrash = U @(23849,28291)
$zhRepair = U @(20462,22797,38382,39064)
$zhRootCause = U @(26681,22240)
$zhStuck = U @(21345,20303)
$zhEngineering = U @(24037,31243)
$zhEngineeringPlan = U @(24037,31243,26041,26696)
$zhArchitecture = U @(26550,26500)
$zhDesign = U @(35774,35745)
$zhRefactor = U @(37325,26500)
$zhModule = U @(27169,22359)
$zhInterface = U @(25509,21475)
$zhTradeoff = U @(26435,34913)
$zhMigration = U @(36801,31227)
$zhProduct = U @(20135,21697)
$zhRequirement = U @(38656,27714)
$zhWorkflow = U @(27969,31243)
$zhEfficiency = U @(25928,29575)
$zhHandoff = U @(20132,25509)
$zhTeach = U @(25945,25105)
$zhLearn = U @(23398,20064)
$zhSkill = U @(25216,33021)
$zhIssue = U @(38382,39064)
$zhTicket = U @(24037,21333)
$zhUserFlow = U @(29992,25143,36335,24452)
$zhSpec = U @(35268,26684)
$zhPrototype = U @(21407,22411)
$zhChallenge = U @(25361,25112)
$zhAssumption = U @(20551,35774)
$zhCounterexample = U @(21453,20363)
$zhRiskReview = U @(39118,38505,23457,26597)
$zhPickApart = U @(25361,21050)
$zhTest = U @(27979,35797)
$zhAcceptance = U @(39564,25910)
$zhRegression = U @(22238,24402)
$zhCoverage = U @(35206,30422,29575)
$zhVerification = U @(39564,35777)
$zhOptimize = U @(20248,21270)
$zhPerformance = U @(24615,33021)
$zhBottleneck = U @(29942,39048)
$zhFaster = U @(25552,36895)
$zhImplement = U @(23454,29616)
$zhDevelop = U @(24320,21457)
$zhAddFeature = U @(28155,21152,21151,33021)
$zhChangeCode = U @(25913,20195,30721)
$zhModify = U @(20462,25913)
$zhHello = U @(20320,22909)
$zhHelloFormal = U @(24744,22909)
$zhHere = U @(22312,21527)
$zhMorning = U @(26089,19978,22909)
$zhAfternoon = U @(19979,21320,22909)
$zhEvening = U @(26202,19978,22909)
$zhThanks = U @(35874,35874)
$zhWhatIs = U @(20160,20040,26159)
$zhExplain = U @(35299,37322)
$zhIntroduce = U @(20171,32461,19968,19979)

function New-RouteResult([bool]$Selected,[string]$Reason,[object[]]$Capabilities = @(),[string[]]$Signals = @(),[string]$State = '',[string]$Code = '',[object[]]$WithheldCapabilities = @(),[string]$RepairAction = '',[object[]]$NativeRouteReceipts = @(),[string]$SelectionPolicy = 'semantic_confidence') {
  if ([string]::IsNullOrWhiteSpace($State)) { $State = if($Selected){'ready'}else{'not_applicable'} }
  if ([string]::IsNullOrWhiteSpace($Code)) { $Code = if($State -eq 'withheld'){'CAPABILITY_ROUTE_WITHHELD'}elseif($Selected){'CAPABILITY_ROUTE_READY'}else{'CAPABILITY_ROUTE_NOT_APPLICABLE'} }
  return [pscustomobject]@{
    ok = ($State -ne 'withheld')
    state = $State
    code = $Code
    schema = 'super-brain.absorbed-capability-route.v1'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    routeMode = 'automatic_semantic_capability_selection'
    selected = $Selected
    reason = $Reason
    query = if ($inputText.Length -gt 260) { $inputText.Substring(0,260) + '...' } else { $inputText }
    intent = $Intent
    semanticSignals = @($Signals)
    capabilityCount = @($Capabilities).Count
    capabilities = @($Capabilities)
    nativeRouteReceipts = @($NativeRouteReceipts)
    selectionPolicy = $SelectionPolicy
    withheldCapabilities = @($WithheldCapabilities)
    repairAction = $RepairAction
    guard = 'A selected capability is a compact, non-authorizing Super Brain instruction card. It cannot override the latest user instruction, H7 scope/contract, project evidence, privacy, mutation approval, or verification.'
    coldLoadPolicy = 'Execute the selected Super Brain native behavior contract at its applyAt phase. A sourcePath is a bounded provenance/cold reference only; never invoke it as a host skill or let it authorize mutation.'
    executionOwner = 'super-memory-brain'
    standaloneInstall = $false
  }
}

function New-NativeRouteReceipt($Candidate) {
  if (-not $Candidate -or -not $Candidate.PSObject.Properties['nativeBehaviorContract'] -or -not $Candidate.nativeBehaviorContract) { return $null }
  $contract = $Candidate.nativeBehaviorContract
  if ([string]$contract.schema -ne 'super-brain.native-capability-contract.v1' -or
      [string]$contract.executionOwner -ne 'super-memory-brain' -or
      [string]$contract.sourceUse -ne 'provenance_cold_reference_only') { return $null }
  if (-not $Candidate.PSObject.Properties['nativeParityMapping'] -or -not $Candidate.nativeParityMapping) { return $null }
  $parityMapping = $Candidate.nativeParityMapping
  if ([string]$parityMapping.schema -ne 'super-brain.native-capability-parity.v1' -or [string]::IsNullOrWhiteSpace([string]$parityMapping.procedureId)) { return $null }
  $parityPayload = [ordered]@{
    capabilityId = [string]$Candidate.capabilityId
    contractId = [string]$contract.id
    contractEntry = [string]$contract.entry
    sourceUse = [string]$contract.sourceUse
    parityMapping = $parityMapping
  }
  return [pscustomobject]@{
    schema = 'super-brain.native-capability-route-receipt.v1'
    capabilityId = [string]$Candidate.capabilityId
    contractId = [string]$contract.id
    entry = [string]$contract.entry
    executionOwner = 'super-memory-brain'
    sourceUse = 'provenance_cold_reference_only'
    applyAt = @($Candidate.applyAt)
    requiredReceipts = @($contract.requiredReceipts)
    verification = @($contract.verification)
    routePriority = [int]$Candidate.routePriority
    parityProcedureId = [string]$parityMapping.procedureId
    parityHash = Get-SuperBrainStableHash (($parityPayload | ConvertTo-Json -Depth 10 -Compress)) 64
  }
}

function Test-ContainsPhrase([string]$Phrase) {
  if ([string]::IsNullOrWhiteSpace($Phrase) -or [string]::IsNullOrWhiteSpace($normalized)) { return $false }
  $needle = $Phrase.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant().Trim()
  if ($needle.Length -lt 2) { return $false }
  if ($normalized.Contains($needle)) { return $true }
  $compactNeedle = $needle -replace '[\s\p{P}\p{S}]', ''
  return $compactNeedle.Length -ge 2 -and $compact.Contains($compactNeedle)
}

function Get-SemanticSignals {
  $definitions = @(
    [pscustomobject]@{ id='bug_diagnosis'; phrases=@('diagnose','debug','bug','error','failed','failure','crash','broken','slow','regression',$zhDiagnose,$zhDebug,$zhError,$zhFailed,$zhCrash,$zhRepair,$zhRootCause,$zhStuck) },
    # The capability family name itself is a valid semantic request.  Users
    # should be able to say “engineering/工程” and receive the native
    # evidence-first engineering route without memorising an upstream skill
    # or a more specific trigger phrase.
    [pscustomobject]@{ id='engineering_design'; phrases=@('engineering','engineering capability','engineering workflow','software engineering','architecture','design','refactor','module','interface','seam','tradeoff','migration','engineering plan',$zhEngineering,$zhEngineeringPlan,$zhArchitecture,$zhDesign,$zhRefactor,$zhModule,$zhInterface,$zhTradeoff,$zhMigration) },
    [pscustomobject]@{ id='product_planning'; phrases=@('product design','product requirement','product specification','prd','requirement','user flow','spec','roadmap','backlog','issue','triage',$zhProduct,$zhRequirement,$zhUserFlow,$zhSpec,$zhIssue,$zhTicket) },
    [pscustomobject]@{ id='productivity_workflow'; phrases=@('productivity','efficiency','efficient workflow','handoff','hand over','next session','workflow',$zhEfficiency,$zhHandoff,$zhWorkflow) },
    [pscustomobject]@{ id='learning_teaching'; phrases=@('teach me','help me learn','learning plan','write a skill','improve a skill',$zhTeach,$zhLearn,$zhSkill) },
    [pscustomobject]@{ id='challenge_assumptions'; phrases=@('challenge','grill','assumption','counterexample','risk review','challenge this',$zhChallenge,$zhAssumption,$zhCounterexample,$zhRiskReview,$zhPickApart) },
    [pscustomobject]@{ id='testing'; phrases=@('test','tdd','coverage','verify','acceptance','regression test',$zhTest,$zhAcceptance,$zhRegression,$zhCoverage,$zhVerification) },
    [pscustomobject]@{ id='optimization'; phrases=@('optimize','performance','bottleneck','efficient',$zhOptimize,$zhPerformance,$zhBottleneck,$zhFaster) },
    [pscustomobject]@{ id='implementation'; phrases=@('implement','build','add feature','change code','fix',$zhImplement,$zhDevelop,$zhAddFeature,$zhChangeCode,$zhModify) }
  )
  $hits = @()
  foreach ($definition in $definitions) {
    if (@($definition.phrases | Where-Object { Test-ContainsPhrase ([string]$_) }).Count -gt 0) { $hits += [string]$definition.id }
  }
  return @($hits | Select-Object -Unique)
}

function Test-DirectSkip {
  if ([string]::IsNullOrWhiteSpace($normalized)) { return 'empty_request' }
  $greetings = @('hi','hello','hey',$zhHello,$zhHelloFormal,$zhHere,$zhMorning,$zhAfternoon,$zhEvening,'thanks','thank you',$zhThanks)
  $flat = $compact
  foreach ($greeting in $greetings) {
    $needle = $greeting -replace '[\s\p{P}\p{S}]', ''
    if ($flat -eq $needle) { return 'ordinary_greeting' }
  }
  if ((($normalized -match '^(what is|what are|explain|define)') -or (Test-ContainsPhrase $zhWhatIs) -or (Test-ContainsPhrase $zhExplain) -or (Test-ContainsPhrase $zhIntroduce)) -and $normalized.Length -lt 80) { return 'simple_concept_answer' }
  if ($Intent -in @('continue','current_task_status','status','historical_recovery','memory_recall','workflow_preference_recall','maintenance_hot_refresh')) { return 'operational_route_only' }
  return ''
}

function Get-CapabilityTags($Capability) {
  $tags = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($tag in @($Capability.semanticTags)) { if (-not [string]::IsNullOrWhiteSpace([string]$tag)) { [void]$tags.Add(([string]$tag).ToLowerInvariant()) } }
  $name = (([string]$Capability.name) + ' ' + ([string]$Capability.capabilityId) + ' ' + ([string]$Capability.role) + ' ' + ([string]$Capability.category)).ToLowerInvariant()
  if ($name -match 'diagnos|bug|root.cause|evidence.ground') { [void]$tags.Add('bug_diagnosis') }
  if ($name -match 'tdd|test|vitest|verification') { [void]$tags.Add('testing') }
  if ($name -match 'grill|challenge') { [void]$tags.Add('challenge_assumptions') }
  if ($name -match 'architecture|codebase.design|domain.model|engineering.decision|design') { [void]$tags.Add('engineering_design') }
  if ($name -match 'prd|triage|issue|prototype|product[_-]planning|requirement') { [void]$tags.Add('product_planning') }
  if ($name -match 'handoff|teach|writing.great.skills|skill.authoring') { [void]$tags.Add('productivity_workflow') }
  if ($name -match 'teach|writing.great.skills|skill.authoring') { [void]$tags.Add('learning_teaching') }
  if ($name -match 'optimiz|performance|evidence.ground') { [void]$tags.Add('optimization') }
  if ($name -match 'ponytail|karpathy|pre.action.constraint') { [void]$tags.Add('implementation') }
  if (@($Capability.applyAt) -contains 'before_mutation') { [void]$tags.Add('implementation') }
  return @($tags)
}

function Get-CapabilityMatch($Capability,[string[]]$Signals) {
  $score = 0
  $reasons = @()
  $hasExplicitTrigger = $false
  $tags = @(Get-CapabilityTags $Capability)
  foreach ($signal in $Signals) {
    if ($tags -contains $signal) {
      $score += 4
      $reasons += ('semantic:' + $signal)
    }
  }
  foreach ($trigger in @($Capability.triggers)) {
    $value = ([string]$trigger).Trim()
    if (Test-ContainsPhrase $value) {
      $hasExplicitTrigger = $true
      $score += if ($value.Length -ge 5) { 4 } else { 3 }
      $reasons += ('trigger:' + $value)
    }
  }
  foreach ($field in @([string]$Capability.name,[string]$Capability.capabilityId)) {
    if (-not [string]::IsNullOrWhiteSpace($field) -and (Test-ContainsPhrase $field)) {
      $score += 5
      $reasons += ('explicit_source_reference:' + $field)
    }
  }
  if ([string]$Capability.role -eq 'pre_action_constraint' -and @($Signals | Where-Object { $_ -in @('implementation','optimization') }).Count -gt 0) {
    $score += 2; $reasons += 'role:pre_action_constraint'
  }
  if ([string]$Capability.role -eq 'challenge_gate' -and @($Signals | Where-Object { $_ -in @('engineering_design','product_planning','challenge_assumptions') }).Count -gt 0) {
    $score += 2; $reasons += 'role:challenge_gate'
  }
  $identity = (([string]$Capability.name) + ' ' + ([string]$Capability.capabilityId)).ToLowerInvariant()
  if (($Signals -contains 'bug_diagnosis') -and $identity -match 'diagnos|bug') { $score += 5; $reasons += 'specialty:bug_diagnosis' }
  if (($Signals -contains 'engineering_design') -and $identity -match 'codebase.design|architecture|domain.model|engineering.decision') { $score += 5; $reasons += 'specialty:engineering_design' }
  if (($Signals -contains 'product_planning') -and $identity -match 'to.prd|to.issues|triage|prototype|product[_-]planning') { $score += 5; $reasons += 'specialty:product_planning' }
  if (($Signals -contains 'productivity_workflow') -and $identity -match 'handoff|teach|writing.great.skills') { $score += 5; $reasons += 'specialty:productivity_workflow' }
  if (($Signals -contains 'learning_teaching') -and $identity -match 'teach|writing.great.skills') { $score += 5; $reasons += 'specialty:learning_teaching' }
  if (($Signals -contains 'challenge_assumptions') -and $identity -match 'grill|challenge') { $score += 5; $reasons += 'specialty:challenge_assumptions' }
  return [pscustomobject]@{ score=$score; reasons=@($reasons | Select-Object -Unique); tags=$tags; hasExplicitTrigger=$hasExplicitTrigger }
}

function Get-SelectedCapabilityProvenance($Candidate) {
  if ([string]$Candidate.sourceKind -ne 'absorbed_package_capability_source') {
    return [pscustomobject]@{ status='not_applicable'; code='CAPABILITY_PROVENANCE_NOT_APPLICABLE'; manifestSha256=''; skillSha256=''; provenanceHash='' }
  }
  $manifestPath = [string]$Candidate.manifestPath
  $skillPath = [string]$Candidate.skillPath
  $manifestSha256 = Get-SuperBrainFileSha256 $manifestPath
  $skillSha256 = if([string]::IsNullOrWhiteSpace($skillPath)){''}else{Get-SuperBrainFileSha256 (Join-Path $skillPath 'SKILL.md')}
  if ([string]::IsNullOrWhiteSpace($manifestSha256) -or [string]::IsNullOrWhiteSpace($skillSha256) -or [string]::IsNullOrWhiteSpace([string]$Candidate.sourceRepo) -or [string]::IsNullOrWhiteSpace([string]$Candidate.sourceCommit) -or [string]::IsNullOrWhiteSpace([string]$Candidate.license)) {
    return [pscustomobject]@{ status='withheld'; code='CAPABILITY_PROVENANCE_UNAVAILABLE'; manifestSha256=$manifestSha256; skillSha256=$skillSha256; provenanceHash='' }
  }
  $provenanceHash = Get-SuperBrainStableHash (([string]$Candidate.sourceRepo) + '|' + ([string]$Candidate.sourceCommit) + '|' + ([string]$Candidate.upstreamPath) + '|' + $manifestSha256 + '|' + $skillSha256) 64
  return [pscustomobject]@{ status='verified'; code='CAPABILITY_PROVENANCE_CURRENT'; manifestSha256=$manifestSha256; skillSha256=$skillSha256; provenanceHash=$provenanceHash }
}

$skipReason = Test-DirectSkip
if ($skipReason) {
  $result = New-RouteResult $false $skipReason @() @()
  if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "ABSORBED_CAPABILITY_ROUTE selected=False reason=$skipReason" }
  exit 0
}

$mapScript = Join-Path $PSScriptRoot 'skill-capability-map.ps1'
try {
  $raw = @(& $mapScript -List -TopK 256 -Json 2>$null)
  if ($LASTEXITCODE -ne 0 -or @($raw).Count -eq 0) { throw 'CAPABILITY_MAP_UNAVAILABLE' }
  $map = (($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop)
  if ($map.ok -ne $true -or [string]$map.state -eq 'withheld') { throw $(if($map.code){[string]$map.code}else{'CAPABILITY_MAP_UNAVAILABLE'}) }
} catch {
  $result = New-RouteResult $false 'capability_map_unavailable' @() @() -State 'withheld' -Code 'CAPABILITY_MAP_UNAVAILABLE' -RepairAction 'Repair the absorbed capability map or its declared source, then retry routing.'
  $result | Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message
  if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host 'ABSORBED_CAPABILITY_ROUTE state=withheld code=CAPABILITY_MAP_UNAVAILABLE' }
  exit 0
}

$signals = @(Get-SemanticSignals)
if (@($signals).Count -eq 0) {
  $result = New-RouteResult $false 'no_high_confidence_capability' @() @()
  if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host 'ABSORBED_CAPABILITY_ROUTE selected=False reason=no_high_confidence_capability' }
  exit 0
}

$candidates = foreach ($capability in @($map.capabilities)) {
  $match = Get-CapabilityMatch $capability $signals
  if ($match.score -lt 4) { continue }
  $routeEligibility = if([string]::IsNullOrWhiteSpace([string]$capability.routeEligibility)){'auto'}else{[string]$capability.routeEligibility}
  if ($routeEligibility -in @('reference_only','adapter_only')) { continue }
  if ($routeEligibility -eq 'explicit_only' -and -not $match.hasExplicitTrigger) { continue }
  $confidence = if ($match.score -ge 9) { 'high' } elseif ($match.score -ge 6) { 'medium' } else { 'low' }
  if ($confidence -eq 'low') { continue }
  [pscustomobject]@{
    capabilityId = if ([string]::IsNullOrWhiteSpace([string]$capability.capabilityId)) { 'sb.core.' + ([string]$capability.name -replace '[^A-Za-z0-9._-]','-') } else { [string]$capability.capabilityId }
    name = [string]$capability.name
    category = [string]$capability.category
    role = [string]$capability.role
    confidence = $confidence
    score = $match.score
    triggerReason = @($match.reasons)
    hasExplicitTrigger = [bool]$match.hasExplicitTrigger
    semanticTags = @($match.tags)
    capabilityUse = @($capability.canDo | Select-Object -First 2)
    applyAt = @($capability.applyAt | Select-Object -First 4)
    verification = @($capability.verification | Select-Object -First 3)
    stopCondition = [string]$capability.stopCondition
    sourcePath = [string]$capability.sourcePath
    skillPath = [string]$capability.skillPath
    manifestPath = [string]$capability.manifestPath
    sourceRepo = [string]$capability.sourceRepo
    sourceCommit = [string]$capability.sourceCommit
    license = [string]$capability.license
    upstreamPath = [string]$capability.upstreamPath
    executionOwner = 'super-memory-brain'
    sourceKind = if ([string]::IsNullOrWhiteSpace([string]$capability.sourceKind)) { 'core_super_brain_capability' } else { [string]$capability.sourceKind }
    sourcePriority = if ([string]$capability.sourceKind -eq 'absorbed_package_capability_source') { 1 } else { 0 }
    upstreamInvocation = if ([string]::IsNullOrWhiteSpace([string]$capability.upstreamInvocation)) { 'super_brain_native' } else { [string]$capability.upstreamInvocation }
    upstreamAuthoredInvocation = [string]$capability.upstreamAuthoredInvocation
    invocationMode = if ([string]::IsNullOrWhiteSpace([string]$capability.superBrainInvocation)) { 'bounded_super_brain_card' } else { [string]$capability.superBrainInvocation }
    adapterTarget = [string]$capability.adapterTarget
    externalActionPolicy = if ([string]::IsNullOrWhiteSpace([string]$capability.externalActionPolicy)) { 'none' } else { [string]$capability.externalActionPolicy }
    projectMutationPolicy = if ([string]::IsNullOrWhiteSpace([string]$capability.projectMutationPolicy)) { 'none' } else { [string]$capability.projectMutationPolicy }
    policySource = if ([string]::IsNullOrWhiteSpace([string]$capability.policySource)) { 'inferred_legacy' } else { [string]$capability.policySource }
    routingMetadataSource = if ([string]::IsNullOrWhiteSpace([string]$capability.routingMetadataSource)) { 'inferred_legacy' } else { [string]$capability.routingMetadataSource }
    routeEligibility = $routeEligibility
    mutualExclusionGroup = [string]$capability.mutualExclusionGroup
    sourceUse = if ([string]::IsNullOrWhiteSpace([string]$capability.sourceUse)) { 'native_capability_card' } else { [string]$capability.sourceUse }
    nativeBehaviorContractId = [string]$capability.nativeBehaviorContractId
    nativeBehaviorContract = if ($capability.PSObject.Properties['nativeBehaviorContract']) { $capability.nativeBehaviorContract } else { $null }
    nativeParityProcedureId = [string]$capability.nativeParityProcedureId
    nativeParityMapping = if ($capability.PSObject.Properties['nativeParityMapping']) { $capability.nativeParityMapping } else { $null }
    standaloneInstall = $false
    compactCard = [pscustomobject]@{
      use = @($capability.canDo | Select-Object -First 2)
      boundary = @($capability.cannotDo | Select-Object -First 2)
      stopCondition = [string]$capability.stopCondition
      verification = @($capability.verification | Select-Object -First 2)
      invocationMode = if ([string]::IsNullOrWhiteSpace([string]$capability.superBrainInvocation)) { 'bounded_super_brain_card' } else { [string]$capability.superBrainInvocation }
      externalActionPolicy = if ([string]::IsNullOrWhiteSpace([string]$capability.externalActionPolicy)) { 'none' } else { [string]$capability.externalActionPolicy }
      projectMutationPolicy = if ([string]::IsNullOrWhiteSpace([string]$capability.projectMutationPolicy)) { 'none' } else { [string]$capability.projectMutationPolicy }
      routeEligibility = $routeEligibility
      sourceUse = if ([string]::IsNullOrWhiteSpace([string]$capability.sourceUse)) { 'native_capability_card' } else { [string]$capability.sourceUse }
      nativeBehaviorContractId = [string]$capability.nativeBehaviorContractId
      nativeParityProcedureId = [string]$capability.nativeParityProcedureId
    }
  }
}

$uniqueCandidates = @($candidates | Group-Object { ([string]$_.name).ToLowerInvariant() } | ForEach-Object { $_.Group | Sort-Object @{Expression={$_.sourcePriority};Descending=$true}, @{Expression={$_.score};Descending=$true} | Select-Object -First 1 })
$limit = [Math]::Max(1,[Math]::Min($TopK,4))
$usedGroups = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
$selectedCandidates = New-Object System.Collections.ArrayList
$selectionPolicy = if ($signals -contains 'challenge_assumptions') { 'challenge_semantic_priority' } else { 'semantic_confidence_with_explicit_tiebreak' }
foreach ($candidate in @($uniqueCandidates)) {
  $isChallengeRoute = ([string]$candidate.role -in @('challenge_gate','design_interview_documentation','interactive_challenge_loop')) -or
    ([string]$candidate.invocationMode -match 'challenge') -or
    ([string]$candidate.adapterTarget -eq 'grilling')
  $semanticPriority = if (($signals -contains 'challenge_assumptions') -and $isChallengeRoute) { 100 } else { 0 }
  $contractPriority = 0
  if ($candidate.nativeBehaviorContract -and $candidate.nativeBehaviorContract.PSObject.Properties['routePriority']) {
    try { $contractPriority = [int]$candidate.nativeBehaviorContract.routePriority } catch { $contractPriority = 0 }
  }
  $candidate | Add-Member -NotePropertyName routePriority -NotePropertyValue ([Math]::Max($semanticPriority,$contractPriority)) -Force
}
# Explicit phrases remain a tiebreaker, not a global filter. A generic word such
# as "test" must not erase a higher-level challenge/design signal in the same request.
$selectionPool = @($uniqueCandidates)
foreach($candidate in @($selectionPool | Sort-Object @{Expression={$_.routePriority};Descending=$true}, @{Expression={ if ($_.hasExplicitTrigger) { 1 } else { 0 } };Descending=$true}, @{Expression={ if ($_.confidence -eq 'high') { 2 } else { 1 } };Descending=$true}, @{Expression={$_.score};Descending=$true}, @{Expression={$_.sourcePriority};Descending=$true}, name)) {
  $group = [string]$candidate.mutualExclusionGroup
  if (-not [string]::IsNullOrWhiteSpace($group) -and $usedGroups.Contains($group)) { continue }
  [void]$selectedCandidates.Add($candidate)
  if (-not [string]::IsNullOrWhiteSpace($group)) { [void]$usedGroups.Add($group) }
  if (@($selectedCandidates).Count -ge $limit) { break }
}

$selected = New-Object System.Collections.ArrayList
$withheldCandidates = New-Object System.Collections.ArrayList
$nativeRouteReceipts = New-Object System.Collections.ArrayList
foreach($candidate in @($selectedCandidates)) {
  $provenance = Get-SelectedCapabilityProvenance $candidate
  if ($provenance.status -eq 'withheld') {
    [void]$withheldCandidates.Add([pscustomobject]@{ capabilityId=[string]$candidate.capabilityId; name=[string]$candidate.name; code=[string]$provenance.code })
    continue
  }
  $candidate | Add-Member -NotePropertyName provenanceStatus -NotePropertyValue ([string]$provenance.status) -Force
  $candidate | Add-Member -NotePropertyName provenanceCode -NotePropertyValue ([string]$provenance.code) -Force
  $candidate | Add-Member -NotePropertyName manifestSha256 -NotePropertyValue ([string]$provenance.manifestSha256) -Force
  $candidate | Add-Member -NotePropertyName sourceManifestHash -NotePropertyValue ([string]$provenance.manifestSha256) -Force
  $candidate | Add-Member -NotePropertyName skillSha256 -NotePropertyValue ([string]$provenance.skillSha256) -Force
  $candidate | Add-Member -NotePropertyName provenanceHash -NotePropertyValue ([string]$provenance.provenanceHash) -Force
  $candidate.compactCard | Add-Member -NotePropertyName provenanceStatus -NotePropertyValue ([string]$provenance.status) -Force
  $candidate.compactCard | Add-Member -NotePropertyName sourceRepo -NotePropertyValue ([string]$candidate.sourceRepo) -Force
  $candidate.compactCard | Add-Member -NotePropertyName sourceCommit -NotePropertyValue ([string]$candidate.sourceCommit) -Force
  $candidate.compactCard | Add-Member -NotePropertyName license -NotePropertyValue ([string]$candidate.license) -Force
  $candidate.compactCard | Add-Member -NotePropertyName sourceManifestHash -NotePropertyValue ([string]$provenance.manifestSha256) -Force
  $candidate.compactCard | Add-Member -NotePropertyName skillSha256 -NotePropertyValue ([string]$provenance.skillSha256) -Force
  $candidate.compactCard | Add-Member -NotePropertyName provenanceHash -NotePropertyValue ([string]$provenance.provenanceHash) -Force
  $nativeRouteReceipt = New-NativeRouteReceipt $candidate
  if ($nativeRouteReceipt) {
    $candidate | Add-Member -NotePropertyName nativeRouteReceipt -NotePropertyValue $nativeRouteReceipt -Force
    $candidate.compactCard | Add-Member -NotePropertyName nativeBehaviorContractId -NotePropertyValue ([string]$nativeRouteReceipt.contractId) -Force
    [void]$nativeRouteReceipts.Add($nativeRouteReceipt)
  }
  [void]$selected.Add($candidate)
}
$reason = if (@($selected).Count -gt 0) { 'high_confidence_semantic_match' } else { 'no_high_confidence_capability' }
if (@($selected).Count -eq 0 -and @($withheldCandidates).Count -gt 0) {
  $result = New-RouteResult $false 'capability_provenance_unavailable' @() $signals -State 'withheld' -Code 'CAPABILITY_PROVENANCE_UNAVAILABLE' -WithheldCapabilities @($withheldCandidates) -RepairAction 'Repair the selected cold capability provenance before loading or applying it.'
} else {
  $result = New-RouteResult (@($selected).Count -gt 0) $reason @($selected) $signals -WithheldCapabilities @($withheldCandidates) -NativeRouteReceipts @($nativeRouteReceipts) -SelectionPolicy $selectionPolicy
}
if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "ABSORBED_CAPABILITY_ROUTE selected=$($result.selected) count=$($result.capabilityCount) reason=$reason" }
exit 0
