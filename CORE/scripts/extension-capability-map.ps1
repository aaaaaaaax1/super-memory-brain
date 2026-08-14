param(
  [string]$Query = '',
  [int]$TopK = 50,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$mapPath = Join-Path $workspace 'absorbed-capability-map.json'
$legacyMapPath = Join-Path $workspace 'extension-capability-map.json'
$outPath = Join-Path $workspace 'last-absorbed-capability-map.json'

function Limit-Text([string]$Value,[int]$Max=360){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function To-Array($Value){ if($null -eq $Value){ return @() }; return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
function Get-SkillSourceMetadata([string]$SkillPath){
  $result = [ordered]@{ description=''; semanticTags=@(); provenance='extension_manifest'; upstreamInvocation='model_invocable_upstream'; superBrainInvocation='bounded_cold_source'; adapterTarget=''; externalActionPolicy='none'; projectMutationPolicy='none' }
  $skillFile = Join-Path $SkillPath 'SKILL.md'
  if(-not (Test-Path -LiteralPath $skillFile -PathType Leaf)){ return [pscustomobject]$result }
  try {
    $head = @(Get-Content -LiteralPath $skillFile -Encoding UTF8 -TotalCount 40)
    if(@($head).Count -ge 3 -and $head[0].Trim() -eq '---'){
      foreach($line in @($head | Select-Object -Skip 1)){
        if($line.Trim() -eq '---'){ break }
        if($line -match '^\s*description\s*:\s*["'']?(.*?)["'']?\s*$'){
          $result.description = ([string]$Matches[1]).Trim()
        }
        if($line -match '^\s*disable-model-invocation\s*:\s*true\s*$'){
          $result.upstreamInvocation = 'user_only_upstream'
        }
      }
    }
  } catch {}
  $hay = (($SkillPath + ' ' + [string]$result.description).ToLowerInvariant())
  $tags = New-Object System.Collections.Generic.List[string]
  if($hay -match 'diagnos|debug|bug|root cause|regression|slow'){ [void]$tags.Add('bug_diagnosis') }
  if($hay -match 'tdd|test|vitest|testing'){ [void]$tags.Add('testing') }
  if($hay -match 'grill|challenge|assumption|counterexample'){ [void]$tags.Add('challenge_assumptions') }
  if($hay -match 'architecture|codebase.design|domain.model|interface|refactor|module'){ [void]$tags.Add('engineering_design') }
  if($hay -match 'prd|requirement|issue|triage|prototype|product[\/_ -]'){ [void]$tags.Add('product_planning') }
  if($hay -match 'optimiz|performance|bottleneck'){ [void]$tags.Add('optimization') }
  if($hay -match 'ponytail|karpathy|minimal|surgical'){ [void]$tags.Add('implementation') }
  $result.semanticTags = @($tags | Select-Object -Unique)
  if(-not [string]::IsNullOrWhiteSpace([string]$result.description)){ $result.provenance = 'source_SKILL_frontmatter' }
  if($result.upstreamInvocation -eq 'user_only_upstream'){
    $result.superBrainInvocation = 'adapted_internal_procedure'
  }
  if($hay -match 'grill-me'){
    $result.superBrainInvocation = 'super_brain_internal_challenge_gate'
    $result.adapterTarget = 'grilling'
  } elseif($hay -match 'grilling'){
    $result.superBrainInvocation = 'super_brain_single_question_challenge_loop'
  } elseif($hay -match 'handoff'){
    $result.superBrainInvocation = 'h7_continuity_adapter'
  }
  # Legacy manifests did not have an explicit policy surface. Preserve their
  # conservative fallback, but let explicit manifest policy win at projection.
  $sourceName = (Split-Path -Leaf $SkillPath).ToLowerInvariant()
  if($sourceName -in @('triage','prototype') -or $hay -match 'publish|issue tracker|comment|apply the outcome|label|close'){
    $result.externalActionPolicy = 'proposal_only_until_exact_user_approval'
  }
  return [pscustomobject]$result
}

function Get-VerifiedExtensionManifests {
  $extensionRoot = Join-Path $Root 'extensions'
  if (-not (Test-Path -LiteralPath $extensionRoot -PathType Container)) { return @() }
  $manifests = @()
  $paths = @(Get-ChildItem -LiteralPath $extensionRoot -Filter 'extension.json' -Recurse -File -ErrorAction Stop | Sort-Object FullName)
  foreach ($manifestPath in $paths) {
    try {
      $manifest = Get-Content -LiteralPath $manifestPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
      throw ('CAPABILITY_MAP_EXTENSION_MANIFEST_INVALID:' + $manifestPath.FullName)
    }
    if ($null -eq $manifest -or [string]::IsNullOrWhiteSpace([string]$manifest.id) -or -not $manifest.PSObject.Properties['skills'] -or $null -eq $manifest.skills) {
      throw ('CAPABILITY_MAP_EXTENSION_MANIFEST_INVALID:' + $manifestPath.FullName)
    }
    $manifest | Add-Member -NotePropertyName manifestPath -NotePropertyValue $manifestPath.FullName -Force
    $manifest | Add-Member -NotePropertyName extensionRoot -NotePropertyValue (Split-Path -Parent $manifestPath.FullName) -Force
    foreach ($skill in @($manifest.skills)) {
      if ($null -eq $skill -or [string]::IsNullOrWhiteSpace([string]$skill.name) -or [string]::IsNullOrWhiteSpace([string]$skill.path)) {
        throw ('CAPABILITY_MAP_SKILL_DESCRIPTOR_INVALID:' + $manifestPath.FullName)
      }
    }
    $manifests += $manifest
  }
  return @($manifests)
}

function Get-ExplicitPolicy([object]$Skill,[object]$Extension,[string]$Name,[string]$Fallback='none') {
  if ($Skill -and $Skill.PSObject.Properties[$Name]) {
    $value = [string]$Skill.$Name
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
  }
  if ($Extension -and $Extension.PSObject.Properties[$Name]) {
    $value = [string]$Extension.$Name
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
  }
  return $Fallback
}

function Get-NativeBehaviorContract([object]$Skill,[object]$Extension,[string]$Category) {
  $contractId = ''
  if ($Skill -and $Skill.PSObject.Properties['nativeBehaviorContractId']) {
    $contractId = ([string]$Skill.nativeBehaviorContractId).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($contractId) -and $Extension -and $Extension.PSObject.Properties['nativeBehaviorContractByCategory'] -and $Extension.nativeBehaviorContractByCategory) {
    $byCategory = $Extension.nativeBehaviorContractByCategory
    if ($byCategory.PSObject.Properties[$Category]) {
      $contractId = ([string]$byCategory.$Category).Trim()
    }
  }
  if ([string]::IsNullOrWhiteSpace($contractId)) { return $null }
  if (-not $Extension -or -not $Extension.PSObject.Properties['nativeBehaviorContracts']) {
    throw ('NATIVE_CAPABILITY_CONTRACT_CATALOG_MISSING:' + [string]$Extension.id)
  }
  $contract = @($Extension.nativeBehaviorContracts | Where-Object { ([string]$_.id).Trim() -eq $contractId } | Select-Object -First 1)
  if (@($contract).Count -ne 1) {
    throw ('NATIVE_CAPABILITY_CONTRACT_MISSING:' + [string]$Extension.id + ':' + $contractId)
  }
  $value = $contract[0]
  foreach ($field in @('schema','id','entry','executionOwner','sourceUse')) {
    if (-not $value.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$value.$field)) {
      throw ('NATIVE_CAPABILITY_CONTRACT_INVALID:' + $contractId + ':' + $field)
    }
  }
  if ([string]$value.schema -ne 'super-brain.native-capability-contract.v1' -or
      [string]$value.executionOwner -ne 'super-memory-brain' -or
      [string]$value.sourceUse -ne 'provenance_cold_reference_only') {
    throw ('NATIVE_CAPABILITY_CONTRACT_INVALID:' + $contractId + ':authority')
  }
  $requiredReceipts = @(To-Array $value.requiredReceipts)
  $verification = @(To-Array $value.verification)
  if ($requiredReceipts.Count -eq 0 -or $verification.Count -eq 0) {
    throw ('NATIVE_CAPABILITY_CONTRACT_INVALID:' + $contractId + ':receipt_or_verification')
  }
  $routePriority = 0
  if ($value.PSObject.Properties['routePriority']) {
    try { $routePriority = [int]$value.routePriority } catch { throw ('NATIVE_CAPABILITY_CONTRACT_INVALID:' + $contractId + ':routePriority') }
  }
  return [pscustomobject][ordered]@{
    schema = [string]$value.schema
    id = [string]$value.id
    entry = [string]$value.entry
    executionOwner = [string]$value.executionOwner
    sourceUse = [string]$value.sourceUse
    requiredReceipts = @($requiredReceipts)
    verification = @($verification)
    routePriority = $routePriority
  }
}

function Get-NativeParityMapping([object]$Skill,[object]$Extension) {
  if (-not $Extension -or [string]$Extension.id -ne 'mattpocock-skills') { return $null }
  $skillName = ([string]$Skill.name).Trim()
  if ([string]::IsNullOrWhiteSpace($skillName) -or -not $Extension.PSObject.Properties['nativeParityBySkill'] -or -not $Extension.nativeParityBySkill) {
    throw ('NATIVE_CAPABILITY_PARITY_CATALOG_MISSING:' + [string]$Extension.id)
  }
  $catalog = $Extension.nativeParityBySkill
  if (-not $catalog.PSObject.Properties[$skillName]) {
    throw ('NATIVE_CAPABILITY_PARITY_MISSING:' + [string]$Extension.id + ':' + $skillName)
  }
  $value = $catalog.PSObject.Properties[$skillName].Value
  foreach ($field in @('schema','procedureId')) {
    if (-not $value.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$value.$field)) {
      throw ('NATIVE_CAPABILITY_PARITY_INVALID:' + $skillName + ':' + $field)
    }
  }
  if ([string]$value.schema -ne 'super-brain.native-capability-parity.v1') {
    throw ('NATIVE_CAPABILITY_PARITY_INVALID:' + $skillName + ':schema')
  }
  $sourceOutcomes = @(To-Array $value.sourceOutcomes)
  $nativeOutcomes = @(To-Array $value.nativeOutcomes)
  $enhancements = @(To-Array $value.enhancements)
  $acceptance = @(To-Array $value.acceptance)
  if ($sourceOutcomes.Count -eq 0 -or $nativeOutcomes.Count -eq 0 -or $enhancements.Count -eq 0 -or $acceptance.Count -eq 0) {
    throw ('NATIVE_CAPABILITY_PARITY_INVALID:' + $skillName + ':outcomes_or_acceptance')
  }
  return [pscustomobject][ordered]@{
    schema = [string]$value.schema
    procedureId = [string]$value.procedureId
    sourceOutcomes = @($sourceOutcomes)
    nativeOutcomes = @($nativeOutcomes)
    enhancements = @($enhancements)
    acceptance = @($acceptance)
  }
}

function Infer-Category([string]$Name,[string[]]$Triggers,[string]$ExtensionId){
  $hay = (($Name,$ExtensionId,($Triggers -join ' ')) -join ' ').ToLowerInvariant()
  if($hay -match 'browser|网页|click|screenshot|cloudflare'){ return 'tool_execution' }
  if($hay -match 'test|tdd|vitest|verify'){ return 'verification' }
  if($hay -match 'react|typescript|vue|frontend|ui|design'){ return 'domain_execution' }
  if($hay -match 'karpathy|overengineering|minimal|ponytail|guideline'){ return 'rule' }
  if($hay -match 'prd|issue|triage|spec|product'){ return 'planning' }
  return 'extension'
}
function Infer-Role([string]$Category,[string]$Name,[string[]]$Triggers){
  $hay = (($Name,($Triggers -join ' ')) -join ' ').ToLowerInvariant()
  if($hay -match 'browser|click|screenshot|cloudflare'){ return 'browser_operator' }
  if($hay -match 'test|tdd|vitest'){ return 'test_strategy' }
  if($hay -match 'ponytail|minimal|overengineering|karpathy|guideline'){ return 'pre_action_constraint' }
  if($hay -match 'prd|spec|issue|triage'){ return 'structured_decision' }
  if($Category -eq 'domain_execution'){ return 'domain_executor' }
  return 'extension_capability'
}
function Get-Terms([string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){ return @() }
  return @($Value.ToLowerInvariant() -split '[^\p{L}\p{Nd}]+' | Where-Object { $_.Length -ge 2 })
}
function Test-PhraseContains([string]$Haystack,[string]$Needle){
  if([string]::IsNullOrWhiteSpace($Haystack) -or [string]::IsNullOrWhiteSpace($Needle)){ return $false }
  return $Haystack.ToLowerInvariant().Contains($Needle.ToLowerInvariant())
}
function Get-CapabilityMatch($Cap,[string]$Needle){
  $empty = [pscustomobject]@{ score=0; matchStrength='none'; matchReason='no_query_match'; matchedTriggers=@() }
  if([string]::IsNullOrWhiteSpace($Needle)){ return $empty }

  $query = $Needle.Trim().ToLowerInvariant()
  $reverseLabNegativePatterns = @('reverse a string','generic security talk','security awareness','user agent','逆向思维','反向排序')
  if(([string]$Cap.name -eq 'reverselab-unified' -or [string]$Cap.extensionId -eq 'reverselab-unified') -and @($reverseLabNegativePatterns | Where-Object { $query.Contains($_) }).Count -gt 0){
    return $empty
  }
  $queryTerms = @(Get-Terms $Needle)
  if(@($queryTerms).Count -eq 0){ return $empty }

  $genericTerms = @('reverse','reversing','security','talk','generic','awareness','string','agent','user','what','common','tips','sort')
  $positiveTriggers = @($Cap.triggers)
  $matchedTriggers = @()
  $bestScore = 0
  $bestReason = 'no_trigger_match'
  $strong = $false

  foreach($trigger in $positiveTriggers){
    $triggerText = ([string]$trigger).Trim()
    if([string]::IsNullOrWhiteSpace($triggerText)){ continue }
    $triggerLower = $triggerText.ToLowerInvariant()
    $triggerTerms = @(Get-Terms $triggerText)
    if(@($triggerTerms).Count -eq 0){ continue }

    if($query -eq $triggerLower -or (Test-PhraseContains $query $triggerLower) -or (Test-PhraseContains $triggerLower $query -and @($queryTerms).Count -gt 1)){
      $matchedTriggers += $triggerText
      $termScore = [Math]::Max(3, @($triggerTerms).Count)
      if($termScore -gt $bestScore){ $bestScore = $termScore; $bestReason = "phrase:$triggerText" }
      $strong = $true
      continue
    }

    $overlap = @($queryTerms | Where-Object { $triggerTerms -contains $_ })
    if(@($overlap).Count -eq 0){ continue }
    $matchedTriggers += $triggerText
    $required = if(@($triggerTerms).Count -le 1){ 1 } else { [Math]::Min(2, @($triggerTerms).Count) }
    $onlyGeneric = (@($queryTerms | Where-Object { $genericTerms -notcontains $_ }).Count -eq 0)
    if(@($overlap).Count -ge $required -and -not $onlyGeneric){
      $score = @($overlap).Count
      if($score -gt $bestScore){ $bestScore = $score; $bestReason = "token_overlap:$triggerText" }
      $strong = $true
    } elseif(-not $onlyGeneric) {
      if($bestScore -lt 1){ $bestScore = 1; $bestReason = "weak_token_overlap:$triggerText" }
    }
  }

  $nameOrId = (([string]$Cap.name),([string]$Cap.extensionId),([string]$Cap.extensionName) -join ' ').ToLowerInvariant()
  $nameTerms = @(Get-Terms $nameOrId)
  $nameOverlap = @($queryTerms | Where-Object { $nameTerms -contains $_ })
  if(@($nameOverlap).Count -gt 0 -and @($queryTerms | Where-Object { $genericTerms -notcontains $_ }).Count -gt 0){
    $bestScore = [Math]::Max($bestScore, @($nameOverlap).Count)
    $bestReason = 'name_or_extension_match'
    $strong = $true
  }

  if($bestScore -le 0){ return $empty }
  return [pscustomobject]@{
    score = $bestScore
    matchStrength = if($strong){'strong'}else{'weak'}
    matchReason = $bestReason
    matchedTriggers = @($matchedTriggers | Select-Object -Unique)
  }
}
function Score-Capability($Cap,[string]$Needle){
  return (Get-CapabilityMatch $Cap $Needle).score
}

$capabilities = New-Object System.Collections.ArrayList
$compilerFailure = ''
try {
  foreach($extension in @(Get-VerifiedExtensionManifests)){
    foreach($skill in @($extension.skills)){
      $triggers = To-Array $skill.triggers
      $skillName = [string]$skill.name
      $category = if($skill.category){[string]$skill.category}else{Infer-Category $skillName $triggers ([string]$extension.id)}
      $role = if($skill.role){[string]$skill.role}else{Infer-Role $category $skillName $triggers}
      $skillPath = Join-Path ([string]$extension.extensionRoot) ([string]$skill.path)
      $skillFile = Join-Path $skillPath 'SKILL.md'
      if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) { throw ('CAPABILITY_MAP_SKILL_SOURCE_MISSING:' + $extension.id + ':' + $skillName) }
      $sourceMetadata = Get-SkillSourceMetadata $skillPath
      $hasExplicitRouting = ($skill.PSObject.Properties['category'] -or $skill.PSObject.Properties['role'] -or $skill.PSObject.Properties['semanticTags'] -or $skill.PSObject.Properties['triggers'] -or $skill.PSObject.Properties['superBrainInvocation'] -or $skill.PSObject.Properties['adapterTarget'] -or $skill.PSObject.Properties['routeEligibility'] -or $skill.PSObject.Properties['mutualExclusionGroup'] -or $skill.PSObject.Properties['nativeBehaviorContractId'])
      $hasExplicitPolicy = ($skill.PSObject.Properties['externalActionPolicy'] -or $skill.PSObject.Properties['projectMutationPolicy'] -or $extension.PSObject.Properties['externalActionPolicy'] -or $extension.PSObject.Properties['projectMutationPolicy'])
      $semanticTags = To-Array $skill.semanticTags
      if(@($semanticTags).Count -eq 0){ $semanticTags = @($sourceMetadata.semanticTags) }
      $setupRequired = if($skill.setupRequired){ [string]$skill.setupRequired } elseif($extension.setupRequired){ [string]$extension.setupRequired } elseif($extension.installNote){ [string]$extension.installNote } else { '' }
      $canDo = To-Array $skill.canDo
      if(@($canDo).Count -eq 0){
        $canDo = @("absorbed source capability: $skillName", "auto-routable from verified metadata and source frontmatter")
        if(-not [string]::IsNullOrWhiteSpace([string]$sourceMetadata.description)){ $canDo += ('source intent: ' + (Limit-Text ([string]$sourceMetadata.description) 220)) }
      }
      $cannotDo = To-Array $skill.cannotDo
      if(@($cannotDo).Count -eq 0){ $cannotDo = @('skip extension setup or safety notes', 'override current user instructions or live evidence') }
      $verification = To-Array $skill.verification
      if(@($verification).Count -eq 0){ $verification = @('extension manifest is valid', 'SKILL.md exists', 'route appears in skill-capability-map query when triggers match') }
      $routeEligibility = Get-ExplicitPolicy $skill $extension 'routeEligibility' 'auto'
      $sourceUse = Get-ExplicitPolicy $skill $extension 'sourceUse' 'legacy_source_metadata'
      $nativeBehaviorContract = Get-NativeBehaviorContract $skill $extension $category
      $nativeParityMapping = Get-NativeParityMapping $skill $extension
      if ($sourceUse -eq 'provenance_cold_reference_only' -and $routeEligibility -notin @('reference_only') -and -not $nativeBehaviorContract) {
        throw ('NATIVE_CAPABILITY_CONTRACT_REQUIRED:' + [string]$extension.id + ':' + $skillName)
      }
      if ([string]$extension.id -eq 'mattpocock-skills' -and -not $nativeParityMapping) {
        throw ('NATIVE_CAPABILITY_PARITY_REQUIRED:' + [string]$extension.id + ':' + $skillName)
      }
      $declaredUpstreamInvocation = Get-ExplicitPolicy $skill $extension 'upstreamInvocation' ([string]$sourceMetadata.upstreamInvocation)
      $declaredSuperBrainInvocation = Get-ExplicitPolicy $skill $extension 'superBrainInvocation' ([string]$sourceMetadata.superBrainInvocation)
      $effectiveUpstreamInvocation = if ($sourceUse -eq 'provenance_cold_reference_only') { 'provenance_cold_reference_only' } else { $declaredUpstreamInvocation }
      $effectiveSuperBrainInvocation = if ($nativeBehaviorContract -and $declaredSuperBrainInvocation -in @('bounded_cold_source','adapted_internal_procedure')) { 'super_brain_native_contract' } else { $declaredSuperBrainInvocation }
      $cap = [pscustomobject]@{
        name = $skillName
        capabilityId = ('sb.' + ([string]$extension.id) + '.' + $skillName)
        category = $category
        role = $role
        canDo = @($canDo)
        cannotDo = @($cannotDo)
        triggers = @($triggers)
        applyAt = if($skill.applyAt){@(To-Array $skill.applyAt)}else{@('planning','execution','verification')}
        verification = @($verification)
        stopCondition = if($skill.stopCondition){[string]$skill.stopCondition}else{'Do not use when trigger intent does not match, setup is missing, or the task is safer with core Super Brain behavior.'}
        extensionId = [string]$extension.id
        extensionName = [string]$extension.name
        manifestPath = [string]$extension.manifestPath
        sourcePath = $skillPath
        skillPath = $skillPath
        executionOwner = 'super-memory-brain'
        sourceKind = 'absorbed_package_capability_source'
        standaloneInstall = $false
        defaultEnabled = $true
        setupRequired = $setupRequired
        description = [string]$sourceMetadata.description
        semanticTags = @($semanticTags | Select-Object -Unique)
        triggerProvenance = if(@($triggers).Count -gt 0 -and $hasExplicitRouting){'manifest_explicit'}else{[string]$sourceMetadata.provenance}
        routingMetadataSource = if($hasExplicitRouting){'manifest_explicit'}else{'inferred_legacy'}
        upstreamInvocation = $effectiveUpstreamInvocation
        upstreamAuthoredInvocation = $declaredUpstreamInvocation
        superBrainInvocation = $effectiveSuperBrainInvocation
        adapterTarget = Get-ExplicitPolicy $skill $extension 'adapterTarget' ([string]$sourceMetadata.adapterTarget)
        externalActionPolicy = Get-ExplicitPolicy $skill $extension 'externalActionPolicy' ([string]$sourceMetadata.externalActionPolicy)
        projectMutationPolicy = Get-ExplicitPolicy $skill $extension 'projectMutationPolicy' ([string]$sourceMetadata.projectMutationPolicy)
        policySource = if($hasExplicitPolicy){'manifest_explicit'}else{'inferred_legacy'}
        routeEligibility = $routeEligibility
        mutualExclusionGroup = Get-ExplicitPolicy $skill $extension 'mutualExclusionGroup' ''
        sourceUse = $sourceUse
        nativeBehaviorContractId = if ($nativeBehaviorContract) { [string]$nativeBehaviorContract.id } else { '' }
        nativeBehaviorContract = $nativeBehaviorContract
        nativeParityProcedureId = if ($nativeParityMapping) { [string]$nativeParityMapping.procedureId } else { '' }
        nativeParityMapping = $nativeParityMapping
        sourceRepo = [string]$extension.sourceRepo
        sourceCommit = [string]$extension.sourceCommit
        license = [string]$extension.license
        upstreamPath = [string]$skill.upstreamPath
        provenance = 'absorbed-capability-map.ps1 (package source retained for provenance, not host installation)'
      }
      [void]$capabilities.Add($cap)
    }
  }
} catch {
  $compilerFailure = $_.Exception.Message
}

if (-not [string]::IsNullOrWhiteSpace($compilerFailure)) {
  $failure = [pscustomobject]@{
    ok = $false
    state = 'withheld'
    code = 'CAPABILITY_MAP_UNAVAILABLE'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    schema = 'super-brain.absorbed-capability-map.v1'
    version = (Get-SuperBrainManifest $Root).version
    query = Limit-Text $Query 260
    count = 0
    total = 0
    capabilities = @()
    repairAction = 'Repair the bundled extension manifest or declared SKILL.md source, then rebuild the absorbed capability map.'
    error = Limit-Text $compilerFailure 240
    executionOwner = 'super-memory-brain'
    standaloneInstall = $false
  }
  if($Json){ $failure | ConvertTo-Json -Depth 10 } else { Write-Host "ABSORBED_CAPABILITY_MAP ok=False state=withheld code=CAPABILITY_MAP_UNAVAILABLE" }
  exit 0
}

$items = @($capabilities)
if(-not [string]::IsNullOrWhiteSpace($Query)){ $items = @($items | ForEach-Object { $match = Get-CapabilityMatch $_ $Query; $_ | Add-Member -NotePropertyName score -NotePropertyValue $match.score -Force; $_ | Add-Member -NotePropertyName matchStrength -NotePropertyValue $match.matchStrength -Force; $_ | Add-Member -NotePropertyName matchReason -NotePropertyValue $match.matchReason -Force; $_ | Add-Member -NotePropertyName matchedTriggers -NotePropertyValue @($match.matchedTriggers) -Force; $_ } | Where-Object { $_.score -gt 0 -and $_.matchStrength -ne 'none' } | Sort-Object @{Expression={if($_.matchStrength -eq 'strong'){1}else{0}};Descending=$true},score,name -Descending | Select-Object -First $TopK) }
else { $items = @($items | Select-Object -First $TopK) }

$result = [pscustomobject]@{
  ok = $true
  state = 'ready'
  code = 'CAPABILITY_MAP_CURRENT'
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.absorbed-capability-map.v1'
  version = (Get-SuperBrainManifest $Root).version
  query = Limit-Text $Query 260
  count = @($items).Count
  total = @($capabilities).Count
  capabilities = @($items)
  guard = 'Verified package sources are absorbed as Super Brain capabilities. Super Brain is the execution owner; source folders are cold provenance references and must not be installed as independent host skills.'
  path = $mapPath
}
 $mapPayload = [pscustomobject]@{ schema='super-brain.absorbed-capability-map.v1'; state='ready'; code='CAPABILITY_MAP_CURRENT'; updatedAt=$result.checkedAt; capabilities=@($capabilities); guard=$result.guard; executionOwner='super-memory-brain'; standaloneInstall=$false }
Write-JsonUtf8NoBom $mapPath $mapPayload 14
# Keep a compatibility alias for existing diagnostics while the public runtime
# reads the absorbed-capability path above.
Write-JsonUtf8NoBom $legacyMapPath $mapPayload 14
Write-JsonUtf8NoBom $outPath $result 14
if($Json){ Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "ABSORBED_CAPABILITY_MAP ok=True count=$($result.count) total=$($result.total) path=$mapPath" }
exit 0

