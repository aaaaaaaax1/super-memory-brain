if (-not (Get-Command Write-JsonUtf8NoBom -ErrorAction SilentlyContinue)) {
  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'common.ps1')
}

function Get-UserAdaptationHash([string]$Value, [int]$Bytes = 12) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Value))
    return -join ($hash[0..([Math]::Min($Bytes,$hash.Length)-1)] | ForEach-Object { $_.ToString('x2') })
  } finally { $sha.Dispose() }
}

function Get-UserAdaptationWorkflowIdentityHash([string]$WorkspaceKey,[string]$WorkflowKey) {
  $workspaceValue=([string]$WorkspaceKey).Trim().ToLowerInvariant();$workflowValue=([string]$WorkflowKey).Trim().ToLowerInvariant()
  if(-not(Test-SuperBrainWorkspaceKey $workspaceValue $workspaceValue)-or$workflowValue-notmatch'^[a-z0-9][a-z0-9._-]{0,79}$'){throw 'USER_ADAPTATION_WORKFLOW_IDENTITY_INVALID'}
  return Get-SuperBrainStableHash ("super-brain.workflow-identity.v1`0$workspaceValue`0$workflowValue") 64
}

function Get-UserAdaptationConfirmationReceipt {
  [CmdletBinding()]
  param([string]$Root,[string]$WorkspaceRoot,[string]$ReceiptPath,[string]$ExpectedSha256,[string]$TaskId,[string]$WorkspaceKey)
  $workspace=if([string]::IsNullOrWhiteSpace($WorkspaceRoot)){Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'}else{[IO.Path]::GetFullPath($WorkspaceRoot)}
  $receiptRoot=Join-Path $workspace 'runtime-state\user-confirmation-receipts';$full=if([IO.Path]::IsPathRooted($ReceiptPath)){[IO.Path]::GetFullPath($ReceiptPath)}else{[IO.Path]::GetFullPath((Join-Path $workspace ($ReceiptPath-replace'/','\')))};$expected=$ExpectedSha256.ToLowerInvariant();$workspaceKeyValue=Get-SuperBrainWorkspaceKey $WorkspaceKey
  $receiptTaskToken='r-'+(Get-SuperBrainStableHash $TaskId 16)
  if($expected-notmatch'^[a-f0-9]{64}$'-or-not(Test-SuperBrainChildPath $receiptRoot $full)-or-not[string]::Equals([IO.Path]::GetFileName($full),($receiptTaskToken+'--'+$expected+'.json'),[StringComparison]::OrdinalIgnoreCase)-or(Get-SuperBrainFileSha256 $full)-ne$expected){throw 'USER_ADAPTATION_CONFIRMATION_RECEIPT_MISMATCH'}
  $record=Read-UserAdaptationJsonStrict $full
  if([string]$record.schema-ne'super-brain.user-adaptation-confirmation-receipt.v2'-or[string]$record.producer-ne'codex_host_user_turn'-or[string]$record.actor-ne'real_user'-or[string]$record.authorityKind-ne'structured_task_choice'-or[string]$record.trustLevel-ne'local_same_user_unattested'-or[string]$record.taskId-ne$TaskId-or[string]$record.taskInstanceId-notmatch'^ti-[a-f0-9]{32}$'-or-not(Test-SuperBrainWorkspaceKey ([string]$record.workspaceKey) $workspaceKeyValue)-or[string]$record.ownerSessionKey-notmatch'^sid-[a-z0-9]{8,128}$'-or$record.rawPromptStored-ne$false-or$record.privacy.rawPromptStored-ne$false-or$record.privacy.rawTranscriptStored-ne$false){throw 'USER_ADAPTATION_CONFIRMATION_RECEIPT_INVALID'}
  $expectedEventHash=Get-SuperBrainStableHash ("$($record.ownerSessionKey)|$($record.taskId)|$($record.taskInstanceId)|$($record.userEvent.instructionSha256)|$([int]$record.contractBinding.acceptedRevision)") 64
  $observedAtValid=$false;try{$observedAtValid=(-not[string]::IsNullOrWhiteSpace([string]$record.userEvent.observedAt)-and[datetime]::Parse([string]$record.userEvent.observedAt)-le(Get-Date).AddMinutes(5))}catch{$observedAtValid=$false}
  if([string]$record.userEvent.eventIdHash-ne$expectedEventHash-or[string]$record.userEvent.instructionSha256-notmatch'^[a-f0-9]{64}$'-or-not$observedAtValid-or[int]$record.contractBinding.acceptedRevision-lt1-or[string]::IsNullOrWhiteSpace([string]$record.contractBinding.planFingerprint)-or[string]::IsNullOrWhiteSpace([string]$record.planBinding.planId)-or[int]$record.planBinding.generation-lt1-or[string]$record.planBinding.originFingerprint-notmatch'^[a-f0-9]{16,32}$'-or[string]$record.planBinding.canonicalFingerprint-notmatch'^[a-f0-9]{16,32}$'){throw 'USER_ADAPTATION_CONFIRMATION_BINDING_INVALID'}
  $selection=$record.selection
  $selectionHash=Get-SuperBrainStableHash (($selection|ConvertTo-Json -Depth 8 -Compress)) 64
  if([string]$record.selectionHash-ne$selectionHash-or[string]$selection.source-ne'accepted_outcome'-or[string]$selection.context-notin@('general','coding','debugging','planning','review','design','release')-or[string]$selection.scope-notin@('project','workflow')){throw 'USER_ADAPTATION_CONFIRMATION_SELECTION_INVALID'}
  $normalizedSignals=@()
  foreach($signal in @($selection.signals)){$typed=ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey ([string]$signal.habitKey) -Value ([string]$signal.value);if($typed.valueKind-ne'enum'-or[string]$signal.valueKind-ne'enum'){throw 'USER_ADAPTATION_CONFIRMATION_SIGNAL_INVALID'};$normalizedSignals+=[pscustomobject]@{habitKey=$typed.habitKey;value=$typed.value;valueKind='enum'}}
  $normalizedSignals=@($normalizedSignals|Sort-Object habitKey,value -Unique);if($normalizedSignals.Count-gt3-or@($normalizedSignals|Group-Object habitKey|Where-Object{$_.Count-gt1}).Count-gt0){throw 'USER_ADAPTATION_CONFIRMATION_SIGNAL_SET_INVALID'}
  $workflowKey=''
  if([string]$selection.scope-eq'workflow'){$workflowKey=([string]$selection.workflow.key).ToLowerInvariant();if([string]$selection.workflow.identitySha256-ne(Get-UserAdaptationWorkflowIdentityHash $workspaceKeyValue $workflowKey)){throw 'USER_ADAPTATION_CONFIRMATION_WORKFLOW_INVALID'}}elseif($selection.workflow){throw 'USER_ADAPTATION_CONFIRMATION_PROJECT_WORKFLOW_FORBIDDEN'}
  $protocol=$null
  if($selection.protocolBinding){$forward=[int]$selection.protocolBinding.forwardPasses;$reverse=[int]$selection.protocolBinding.reversePasses;$riskFloor=([string]$selection.protocolBinding.riskFloor).ToLowerInvariant();if($forward-lt1-or$forward-gt5-or$reverse-lt0-or$reverse-gt3-or$riskFloor-notin@('workflow','structural')){throw 'USER_ADAPTATION_CONFIRMATION_PROTOCOL_INVALID'};$protocol=[pscustomobject]@{forwardPasses=$forward;reversePasses=$reverse;riskFloor=$riskFloor};if($selection.protocolBinding.PSObject.Properties['contexts']){$protocolContexts=@($selection.protocolBinding.contexts|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique);if($protocolContexts.Count-lt1-or$protocolContexts.Count-gt6-or@($protocolContexts|Where-Object{$_-notin@('coding','debugging','planning','review','design','release')}).Count-gt0){throw 'USER_ADAPTATION_CONFIRMATION_PROTOCOL_CONTEXT_INVALID'};$protocol|Add-Member -NotePropertyName contexts -NotePropertyValue @($protocolContexts) -Force}}
  if($normalizedSignals.Count-eq0-and-not$protocol){throw 'USER_ADAPTATION_CONFIRMATION_SELECTION_REQUIRED'}
  $relative=$full.Substring($workspace.Length).TrimStart('\','/')-replace'\\','/'
  return [pscustomobject]@{ok=$true;record=$record;path=$full;recordRelativePath=$relative;sha256=$expected;selectionHash=$selectionHash;signals=@($normalizedSignals);protocolBinding=$protocol;context=[string]$selection.context;scope=[string]$selection.scope;workflowKey=$workflowKey;trustLevel='local_same_user_unattested';rawPromptStored=$false}
}

function Test-UserAdaptationConfirmationContractBinding($Confirmation,$Contract) {
  $issues=New-Object Collections.Generic.List[string]
  $record=if($Confirmation-and$Confirmation.PSObject.Properties['record']){$Confirmation.record}else{$null}
  if(-not$record){$issues.Add('receipt_missing')}
  if(-not$Contract){$issues.Add('contract_missing')}
  if($record-and$Contract){
    if([string]$record.ownerSessionKey-ne[string]$Contract.ownerSessionKey){$issues.Add('owner_session')}
    if([string]$record.taskInstanceId-ne[string]$Contract.taskInstanceId){$issues.Add('task_instance')}
    if([int]$record.contractBinding.acceptedRevision-gt[int]$Contract.revision){$issues.Add('accepted_revision')}
    if(-not$Contract.canonicalPlan){$issues.Add('canonical_plan_missing')}
    else{
      if([string]$record.planBinding.planId-ne[string]$Contract.canonicalPlan.planId){$issues.Add('plan_id')}
      if([int]$record.planBinding.generation-ne[int]$Contract.canonicalPlan.generation){$issues.Add('plan_generation')}
      if([string]$record.planBinding.originFingerprint-ne[string]$Contract.canonicalPlan.originFingerprint){$issues.Add('plan_origin')}
      if([string]$record.planBinding.canonicalFingerprint-ne[string]$Contract.canonicalPlan.currentFingerprint){$issues.Add('canonical_fingerprint')}
    }
    if([int]$record.contractBinding.acceptedRevision-eq[int]$Contract.revision-and[string]$record.contractBinding.planFingerprint-ne[string]$Contract.planReceipt.planFingerprint){$issues.Add('plan_fingerprint')}
  }
  return [pscustomobject]@{ok=($issues.Count-eq0);issues=@($issues);taskInstanceId=if($record){[string]$record.taskInstanceId}else{''};acceptedRevision=if($record){[int]$record.contractBinding.acceptedRevision}else{0}}
}

function Get-UserAdaptationPolicy([string]$Root) {
  $policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $policy.userAdaptation -or $policy.userAdaptation.enabled -ne $true) { throw 'USER_ADAPTATION_POLICY_MISSING_OR_DISABLED' }
  return $policy.userAdaptation
}

function Get-UserAdaptationPaths([string]$Root, [string]$WorkspaceRoot = '') {
  $policy = Get-UserAdaptationPolicy $Root
  $workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace' } else { [IO.Path]::GetFullPath($WorkspaceRoot) }
  $directory = Join-Path $workspace ([string]$policy.storage.directory)
  return [pscustomobject]@{
    workspace = $workspace
    directory = $directory
    coordination = Join-Path $directory 'state.coordination'
    state = Join-Path $directory 'state.json'
    observations = Join-Path $directory 'observations.json'
    candidates = Join-Path $directory 'candidates.json'
    profile = Join-Path $directory 'profile.json'
    tombstones = Join-Path $directory 'tombstones.json'
    receipts = Join-Path $directory 'receipts.json'
    storeV2 = Join-Path $directory 'store.v2.json'
    migration = Join-Path $directory 'migration'
    hotProjection = Join-Path $workspace ([string]$policy.nativeProjection.relativePath)
  }
}

function Read-UserAdaptationJson([string]$Path, $Default) {
  if (-not (Test-Path -LiteralPath $Path)) { return $Default }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { return $Default }
}

function Write-UserAdaptationJson([string]$Path, $Value, [int]$Depth = 12, [switch]$Compact) {
  if ($Compact) { Write-Utf8NoBom $Path ($Value | ConvertTo-Json -Depth $Depth -Compress) }
  else { Write-JsonUtf8NoBom $Path $Value $Depth }
}

function Write-UserAdaptationJsonLockHeld([string]$Path,$Value,[int]$Depth=30,[ValidateSet('none','before_replace')][string]$FaultPoint='none') {
  $full=[IO.Path]::GetFullPath($Path)
  $directory=Split-Path -Parent $full
  if(-not(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Force -Path $directory|Out-Null}
  $pending=Join-Path $directory ('.pending-'+[guid]::NewGuid().ToString('n')+'.json')
  $backup=Join-Path $directory ('.replace-backup-'+[guid]::NewGuid().ToString('n')+'.json')
  try{
    [IO.File]::WriteAllText($pending,($Value|ConvertTo-Json -Depth $Depth -Compress),[Text.UTF8Encoding]::new($false))
    if($FaultPoint-eq'before_replace'){throw 'USER_ADAPTATION_FAULT_BEFORE_STORE_REPLACE'}
    if(Test-Path -LiteralPath $full){[IO.File]::Replace($pending,$full,$backup)}else{[IO.File]::Move($pending,$full)}
  }finally{if(Test-Path -LiteralPath $pending){Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue};if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue}}
}

function Read-UserAdaptationJsonStrict([string]$Path,[string[]]$AllowedSchemas=@()) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { throw "USER_ADAPTATION_MIGRATION_SOURCE_INVALID path=$Path" }
  if ($AllowedSchemas.Count -gt 0 -and @($AllowedSchemas) -notcontains [string]$value.schema) {
    throw "USER_ADAPTATION_MIGRATION_SCHEMA_INVALID path=$Path schema=$([string]$value.schema)"
  }
  return $value
}

function Get-UserAdaptationPolicyHash([string]$Root) {
  $policy = Get-UserAdaptationPolicy $Root
  return Get-UserAdaptationHash ($policy | ConvertTo-Json -Depth 30 -Compress) 32
}

function Get-UserAdaptationIdentity([string]$Scope,[string]$ScopeKey,[string]$HabitKey) {
  $resolvedScopeKey = Resolve-UserAdaptationScopeKey $Scope $ScopeKey
  $identity = "$Scope|$resolvedScopeKey|$HabitKey"
  return [pscustomobject]@{ key=$identity; hash=(Get-UserAdaptationHash $identity 16) }
}

function Assert-UserAdaptationPolicyV2([string]$Root) {
  $policy = Get-UserAdaptationPolicy $Root
  $issues = New-Object Collections.Generic.List[string]
  if ([int]$policy.schemaVersion -ne 2) { $issues.Add('schema_version') }
  if ([int]$policy.packet.maxDirectives -gt 3) { $issues.Add('packet_directives') }
  if ([int]$policy.packet.maxTokens -gt 96) { $issues.Add('packet_tokens') }
  if ([int]$policy.packet.maxChars -gt 384) { $issues.Add('packet_chars') }
  if ([int]$policy.storage.maxProjectionBytes -gt 8192) { $issues.Add('projection_bytes') }
  if ($policy.packet.alwaysOnInjection -ne $false) { $issues.Add('always_on_injection') }
  if ([int]$policy.packet.ordinaryChatReads -ne 0) { $issues.Add('ordinary_chat_reads') }
  if ($policy.packet.powerShellFallback -ne $false) { $issues.Add('powershell_fallback') }
  foreach ($required in @('durable_explicit','task_instruction','verified_outcome','workflow_measurement','verified_correction')) {
    if (-not $policy.evidenceKinds.PSObject.Properties[$required]) { $issues.Add("evidence_kind:$required") }
  }
  if(-not$policy.confirmationReceipts-or[string]$policy.confirmationReceipts.schema-ne'super-brain.user-adaptation-confirmation-receipt.v2'-or[string]$policy.confirmationReceipts.producer-ne'codex_host_user_turn'-or[string]$policy.confirmationReceipts.trustLevel-ne'local_same_user_unattested'-or$policy.confirmationReceipts.contentAddressed-ne$true-or$policy.confirmationReceipts.testPromptWrites-ne$false-or$policy.confirmationReceipts.subagentWrites-ne$false-or$policy.confirmationReceipts.callerAssertionsAreAuthority-ne$false){$issues.Add('confirmation_receipt_contract')}
  if(-not$policy.evolution-or[string]$policy.evolution.schema-ne'super-brain.user-adaptation-evolution.v1'-or[string]$policy.evolution.trustLevel-ne'local_same_user_unattested'-or[string]$policy.evolution.metrics.claimPolicy-ne'not_scored_without_paired_blinded_comparison_manifest'-or$policy.evolution.history.requireCompleteReceiptChainForMetrics-ne$true-or$policy.evolution.experienceTransfer.ordinaryChatReads-ne0){$issues.Add('evolution_contract')}
  if($policy.trustedCapture.blockAware-ne$true-or$policy.trustedCapture.currentUserTemplatesOnly-ne$true){$issues.Add('trusted_capture_boundary')}
  if([int]$policy.promotion.minimumDistinctDates-lt2-or[int]$policy.promotion.parameterizedMinimumDistinctDates-lt2){$issues.Add('distinct_date_gate')}
  foreach ($required in @('speaking_style','detail_control','progress_cadence','review_protocol')) {
    if (-not $policy.habits.PSObject.Properties[$required]) { $issues.Add("habit:$required") }
  }
  $review = $policy.habits.review_protocol
  if ([string]$review.valueKind -ne 'bounded_parameters') { $issues.Add('review_protocol_value_kind') }
  foreach ($required in @('forwardPasses','reversePasses','riskFloor')) {
    if (-not $review.parameters.PSObject.Properties[$required]) { $issues.Add("review_parameter:$required") }
  }
  if ($issues.Count -gt 0) { throw ('USER_ADAPTATION_V2_POLICY_INVALID issues=' + ($issues -join ',')) }
  return [pscustomobject]@{
    ok = $true
    schema = 'super-brain.user-adaptation-policy-contract.v2'
    schemaVersion = 2
    policyHash = Get-UserAdaptationPolicyHash $Root
    habitCount = @($policy.habits.PSObject.Properties).Count
    evidenceKindCount = @($policy.evidenceKinds.PSObject.Properties).Count
    packet = [pscustomobject]@{ maxDirectives=[int]$policy.packet.maxDirectives; maxTokens=[int]$policy.packet.maxTokens; maxChars=[int]$policy.packet.maxChars }
    rawPromptStored = $false
  }
}

function ConvertTo-UserAdaptationTypedValue {
  param([string]$Root,[string]$HabitKey,[string]$Value,$Parameters=$null)
  $policy = Get-UserAdaptationPolicy $Root
  $rule = Get-UserAdaptationHabitRule $policy $HabitKey $Value
  $habit = $policy.habits.PSObject.Properties[$rule.habitKey].Value
  $valueKind = if ($habit.PSObject.Properties['valueKind']) { [string]$habit.valueKind } else { 'enum' }
  $parameterProperties = @()
  if ($null -ne $Parameters) {
    if ($Parameters -is [Collections.IDictionary]) { $parameterProperties = @($Parameters.Keys | ForEach-Object { [pscustomobject]@{Name=[string]$_;Value=$Parameters[$_]} }) }
    elseif ($Parameters.PSObject) { $parameterProperties = @($Parameters.PSObject.Properties) }
  }
  if ($valueKind -eq 'enum') {
    if ($parameterProperties.Count -gt 0) { throw 'USER_ADAPTATION_PARAMETERS_NOT_ALLOWED' }
    return [pscustomobject]@{ habitKey=$rule.habitKey; value=$rule.value; valueKind='enum'; parameters=[pscustomobject]@{}; parameterHash=(Get-UserAdaptationHash '{}') }
  }
  if ($valueKind -ne 'bounded_parameters') { throw 'USER_ADAPTATION_VALUE_KIND_INVALID' }
  $definitions = @($habit.parameters.PSObject.Properties)
  foreach ($property in $parameterProperties) {
    if (-not $habit.parameters.PSObject.Properties[[string]$property.Name]) { throw "USER_ADAPTATION_PARAMETER_UNKNOWN name=$([string]$property.Name)" }
  }
  $validated = [ordered]@{}
  foreach ($definitionProperty in $definitions) {
    $name = [string]$definitionProperty.Name
    $definition = $definitionProperty.Value
    $provided = @($parameterProperties | Where-Object { [string]$_.Name -eq $name } | Select-Object -First 1)
    if ($provided.Count -ne 1) { if($definition.optional-eq$true){continue};throw "USER_ADAPTATION_PARAMETER_REQUIRED name=$name" }
    $raw = $provided[0].Value
    if ([string]$definition.type -eq 'integer') {
      if ($raw -isnot [byte] -and $raw -isnot [sbyte] -and $raw -isnot [int16] -and $raw -isnot [uint16] -and $raw -isnot [int32] -and $raw -isnot [uint32] -and $raw -isnot [int64] -and $raw -isnot [uint64]) { throw "USER_ADAPTATION_PARAMETER_TYPE_INVALID name=$name" }
      $number = [int]$raw
      if ($number -lt [int]$definition.minimum -or $number -gt [int]$definition.maximum) { throw "USER_ADAPTATION_PARAMETER_RANGE_INVALID name=$name" }
      $validated[$name] = $number
    } elseif ([string]$definition.type -eq 'enum') {
      $text = ([string]$raw).Trim().ToLowerInvariant()
      if (@($definition.values) -notcontains $text) { throw "USER_ADAPTATION_PARAMETER_VALUE_INVALID name=$name" }
      $validated[$name] = $text
    } elseif ([string]$definition.type -eq 'enum_array') {
      if($raw-is[string]-or$raw-isnot[Collections.IEnumerable]){throw "USER_ADAPTATION_PARAMETER_TYPE_INVALID name=$name"}
      $items=@($raw|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Select-Object -Unique)
      if($items.Count-lt[int]$definition.minimumItems-or$items.Count-gt[int]$definition.maximumItems-or@($items|Where-Object{@($definition.values)-notcontains$_}).Count-gt0){throw "USER_ADAPTATION_PARAMETER_VALUE_INVALID name=$name"}
      $validated[$name]=@($items|Sort-Object)
    } else { throw "USER_ADAPTATION_PARAMETER_DEFINITION_INVALID name=$name" }
  }
  $object = [pscustomobject]$validated
  return [pscustomobject]@{ habitKey=$rule.habitKey; value=$rule.value; valueKind=$valueKind; parameters=$object; parameterHash=(Get-UserAdaptationHash ($object|ConvertTo-Json -Compress)) }
}

function Get-UserAdaptationVerifiedReviewProtocolMeasurement([string]$Measurement,$Contract) {
  $normalized=(($Measurement.Trim()-replace'\s+','').ToLowerInvariant())
  if($normalized-notmatch'^review_protocol=multi_pass;forwardpasses=([1-5]);reversepasses=([0-3]);riskfloor=(workflow|structural)(?:;contexts=(?:coding|debugging|planning|review|design|release)(?:,(?:coding|debugging|planning|review|design|release))*)?$'){return [pscustomobject]@{ok=$false;reason='measurement_invalid';value=''}}
  $expectedForward=[int]$Matches[1];$expectedReverse=[int]$Matches[2];$expectedRisk=[string]$Matches[3]
  if(-not$Contract-or-not$Contract.canonicalPlan-or[string]$Contract.canonicalPlan.orderConfidence-ne'verified'-or[string]$Contract.canonicalPlan.approvalSource-ne'user_confirmation'){return [pscustomobject]@{ok=$false;reason='verified_canonical_plan_required';value=''}}
  $completedItems=@($Contract.canonicalPlan.items|Where-Object{[string]$_.status-eq'completed'})
  $reversePattern='(?i:\breverse(?:-audit| audit| review)\b)|(?:\u53cd\u5ba1|\u53cd\u5411\u5ba1\u8ba1)'
  $forwardPattern='(?i:\b(?:forward review|review pass|audit pass|review round|audit round)\b)|(?<!\u53cd)(?:\u5ba1\u6838|\u5ba1\u8ba1)'
  $reverseItems=@($completedItems|Where-Object{[string]$_.label-match$reversePattern})
  $forwardItems=@($completedItems|Where-Object{[string]$_.label-notmatch$reversePattern-and[string]$_.label-match$forwardPattern})
  $protocolItems=@($forwardItems+$reverseItems)
  if(@($protocolItems|Where-Object{[string]::IsNullOrWhiteSpace([string]$_.itemId)}).Count-gt0-or@($protocolItems.itemId|Select-Object -Unique).Count-ne$protocolItems.Count){return [pscustomobject]@{ok=$false;reason='independent_completed_plan_items_required';value=''}}
  $actualForward=@($forwardItems.itemId|Select-Object -Unique).Count;$actualReverse=@($reverseItems.itemId|Select-Object -Unique).Count
  $planMaterial=(@($Contract.canonicalPlan.items.label)+@($Contract.constraints)+@($Contract.acceptanceCriteria))-join' '
  $actualRisk=if($planMaterial-match'(?i:\b(?:structural|architecture|system boundary|cross-module)\b)|(?:\u7ed3\u6784|\u67b6\u6784|\u7cfb\u7edf\u8fb9\u754c|\u8de8\u6a21\u5757|\u5168\u94fe\u8def)'){'structural'}else{'workflow'}
  if($actualForward-ne$expectedForward-or$actualReverse-ne$expectedReverse-or$actualRisk-ne$expectedRisk){return [pscustomobject]@{ok=$false;reason='measurement_not_proven_by_completed_plan';value='';actualForward=$actualForward;actualReverse=$actualReverse;actualRisk=$actualRisk}}
  return [pscustomobject]@{ok=$true;reason='verified_canonical_plan_protocol';value=$normalized;actualForward=$actualForward;actualReverse=$actualReverse;actualRisk=$actualRisk;planFingerprint=[string]$Contract.canonicalPlan.currentFingerprint}
}

function New-UserAdaptationV2StoreDefaults {
  return [pscustomobject]@{
    state = [pscustomobject]@{ schema='super-brain.user-adaptation-state.v2'; revision=0; generation=1; enabled=$true; updatedAt=''; rawPromptStored=$false }
    observations = [pscustomobject]@{ schema='super-brain.user-adaptation-observations.v2'; revision=0; generation=1; updatedAt=''; items=@(); rawPromptStored=$false }
    candidates = [pscustomobject]@{ schema='super-brain.user-adaptation-candidates.v2'; revision=0; generation=1; updatedAt=''; items=@(); rawPromptStored=$false }
    profile = [pscustomobject]@{ schema='super-brain.user-adaptation-profile.v2'; revision=0; generation=1; policyHash=''; updatedAt=''; entries=@(); profilePressure='ok'; rawPromptStored=$false }
    tombstones = [pscustomobject]@{ schema='super-brain.user-adaptation-tombstones.v2'; revision=0; generation=1; updatedAt=''; items=@(); legacyPreferenceHashes=@(); rawPromptStored=$false }
    receipts = [pscustomobject]@{ schema='super-brain.user-adaptation-receipts.v2'; revision=0; generation=1; updatedAt=''; items=@(); rawPromptStored=$false }
  }
}

function ConvertTo-UserAdaptationV2ProfileEntry([string]$Root,$Entry) {
  $typed = ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey ([string]$Entry.habitKey) -Value ([string]$Entry.value)
  $identity = Get-UserAdaptationIdentity ([string]$Entry.scope) ([string]$Entry.scopeKey) ([string]$Entry.habitKey)
  return [pscustomobject]@{
    preferenceId = [string]$Entry.preferenceId
    identityHash = $identity.hash
    identityGeneration = 1
    scope = [string]$Entry.scope
    scopeKey = [string]$Entry.scopeKey
    habitKey = $typed.habitKey
    value = $typed.value
    valueKind = $typed.valueKind
    parameters = $typed.parameters
    parameterHash = $typed.parameterHash
    source = [string]$Entry.source
    baseConfidence = [double]$Entry.confidence
    confidence = [double]$Entry.confidence
    supportCount = [int]$Entry.supportCount
    distinctTaskCount = [int]$Entry.distinctTaskCount
    distinctContextCount = [int]$Entry.distinctContextCount
    contradictionCount = [int]$Entry.contradictionCount
    contexts = @($Entry.contexts)
    status = [string]$Entry.status
    lastEvidenceAt = [string]$Entry.updatedAt
    updatedAt = [string]$Entry.updatedAt
    rawPromptStored = $false
  }
}

function Get-UserAdaptationMigrationPreview([string]$Root,[string]$WorkspaceRoot='') {
  $contract = Assert-UserAdaptationPolicyV2 $Root
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  $specs = @(
    [pscustomobject]@{name='state';path=$paths.state;v1='super-brain.user-adaptation-state.v1';v2='super-brain.user-adaptation-state.v2';collection=''},
    [pscustomobject]@{name='observations';path=$paths.observations;v1='super-brain.user-adaptation-observations.v1';v2='super-brain.user-adaptation-observations.v2';collection='items'},
    [pscustomobject]@{name='candidates';path=$paths.candidates;v1='super-brain.user-adaptation-candidates.v1';v2='super-brain.user-adaptation-candidates.v2';collection='items'},
    [pscustomobject]@{name='profile';path=$paths.profile;v1='super-brain.user-adaptation-profile.v1';v2='super-brain.user-adaptation-profile.v2';collection='entries'},
    [pscustomobject]@{name='tombstones';path=$paths.tombstones;v1='super-brain.user-adaptation-tombstones.v1';v2='super-brain.user-adaptation-tombstones.v2';collection='items'}
  )
  $files = New-Object Collections.ArrayList
  $issues = New-Object Collections.Generic.List[string]
  $sourceHashes = New-Object Collections.Generic.List[string]
  $profileEntries = @()
  foreach ($spec in $specs) {
    $exists = Test-Path -LiteralPath $spec.path -PathType Leaf
    $value = $null
    if ($exists) {
      try { $value = Read-UserAdaptationJsonStrict $spec.path @($spec.v1,$spec.v2) }
      catch { $issues.Add($_.Exception.Message) }
    }
    $schema = if($value){[string]$value.schema}else{''}
    if ($value -and $schema -eq [string]$spec.v2) { $issues.Add("mixed_or_already_v2:$($spec.name)") }
    $count = if($value -and -not [string]::IsNullOrWhiteSpace($spec.collection)){@($value.($spec.collection)).Count}else{0}
    $hash = if($exists){Get-SuperBrainFileSha256 $spec.path}else{''}
    if (-not [string]::IsNullOrWhiteSpace($hash)) { $sourceHashes.Add("$($spec.name):$hash") }
    if ($spec.name -eq 'profile' -and $value) { $profileEntries = @($value.entries) }
    [void]$files.Add([pscustomobject]@{name=$spec.name;exists=[bool]$exists;sourceSchema=$schema;targetSchema=$spec.v2;itemCount=$count;sha256=$hash;pathStored=$false})
  }
  $convertedEntries = New-Object Collections.ArrayList
  foreach ($entry in $profileEntries) {
    try { [void]$convertedEntries.Add((ConvertTo-UserAdaptationV2ProfileEntry $Root $entry)) }
    catch { $issues.Add("profile_entry:$($_.Exception.Message)") }
  }
  $defaults = New-UserAdaptationV2StoreDefaults
  $targetSchemas = [ordered]@{}
  foreach ($name in @('state','observations','candidates','profile','tombstones','receipts')) { $targetSchemas[$name] = [string]$defaults.$name.schema }
  $fingerprintSeed = @($sourceHashes | Sort-Object) -join '|'
  $migrationId = 'adapt-v2-' + (Get-UserAdaptationHash ("$fingerprintSeed|$($contract.policyHash)") 10)
  return [pscustomobject]@{
    ok = ($issues.Count -eq 0)
    action = 'MigratePreview'
    schema = 'super-brain.user-adaptation-migration-preview.v2'
    migrationId = $migrationId
    sourceVersion = 1
    targetVersion = 2
    expectedRevision = 0
    mutationPerformed = $false
    applicable = ($issues.Count -eq 0)
    files = @($files)
    sourceFileCount = @($files|Where-Object{$_.exists}).Count
    profileEntryCount = $profileEntries.Count
    preservedProfileEntryCount = $convertedEntries.Count
    targetSchemas = [pscustomobject]$targetSchemas
    backupRequired = $true
    rollbackReceiptSchema = 'super-brain.user-adaptation-rollback-receipt.v2'
    compareAndSwapRequired = $true
    policyHash = $contract.policyHash
    issues = @($issues)
    rawPromptStored = $false
    privateValuesReturned = $false
  }
}

function Get-UserAdaptationProperty($Value,[string]$Name,$Default=$null) {
  if ($null -ne $Value -and $Value.PSObject -and $Value.PSObject.Properties[$Name]) { return $Value.$Name }
  return $Default
}

function Get-UserAdaptationEvidenceKind([string]$Source) {
  switch ($Source) {
    'explicit_user' { return [pscustomobject]@{kind='durable_explicit';producer='trusted_direct_statement';promotionEligible=$true} }
    'accepted_outcome' { return [pscustomobject]@{kind='verified_outcome';producer='task_verification';promotionEligible=$true} }
    'user_correction' { return [pscustomobject]@{kind='verified_correction';producer='closed_correction';promotionEligible=$true} }
    default { return [pscustomobject]@{kind='task_instruction';producer='legacy_v1_untrusted';promotionEligible=$false} }
  }
}

function ConvertTo-UserAdaptationV2Observation([string]$Root,$Observation) {
  $typed = ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey ([string]$Observation.habitKey) -Value ([string]$Observation.value)
  $identity = Get-UserAdaptationIdentity ([string]$Observation.scope) ([string]$Observation.scopeKey) ([string]$Observation.habitKey)
  $evidence = Get-UserAdaptationEvidenceKind ([string]$Observation.source)
  $recordedAt = [string]$Observation.recordedAt
  return [pscustomobject]@{
    observationId = [string]$Observation.observationId
    identityHash = $identity.hash
    identityGeneration = 1
    habitKey = $typed.habitKey
    value = $typed.value
    valueKind = $typed.valueKind
    parameters = $typed.parameters
    parameterHash = $typed.parameterHash
    signal = [string]$Observation.signal
    source = [string]$Observation.source
    evidenceKind = $evidence.kind
    producer = $evidence.producer
    promotionEligible = [bool]$evidence.promotionEligible
    scope = [string]$Observation.scope
    scopeKey = [string]$Observation.scopeKey
    context = [string]$Observation.context
    taskId = [string]$Observation.taskId
    evidenceHash = [string]$Observation.evidenceHash
    evidenceDate = if([string]::IsNullOrWhiteSpace($recordedAt)){''}else{try{([datetime]$recordedAt).ToString('yyyy-MM-dd')}catch{''}}
    recordedAt = $recordedAt
    rawPromptStored = $false
  }
}

function ConvertTo-UserAdaptationV2Candidate([string]$Root,$Candidate) {
  $typed = ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey ([string]$Candidate.habitKey) -Value ([string]$Candidate.value)
  $identity = Get-UserAdaptationIdentity ([string]$Candidate.scope) ([string]$Candidate.scopeKey) ([string]$Candidate.habitKey)
  $legacyStatus = [string]$Candidate.status
  $status = switch ($legacyStatus) { 'eligible' {'validated'} 'promoted' {'active'} 'conflicted' {'conflicted'} 'forgotten' {'forgotten'} default {'candidate'} }
  return [pscustomobject]@{
    candidateId = [string]$Candidate.candidateId
    preferenceId = [string]$Candidate.preferenceId
    identityHash = $identity.hash
    identityGeneration = 1
    scope = [string]$Candidate.scope
    scopeKey = [string]$Candidate.scopeKey
    habitKey = $typed.habitKey
    value = $typed.value
    valueKind = $typed.valueKind
    parameters = $typed.parameters
    parameterHash = $typed.parameterHash
    source = [string]$Candidate.source
    baseConfidence = [double]$Candidate.confidence
    confidence = [double]$Candidate.confidence
    supportCount = [int]$Candidate.supportCount
    distinctTaskCount = [int]$Candidate.distinctTaskCount
    distinctContextCount = [int]$Candidate.distinctContextCount
    contradictionCount = [int]$Candidate.contradictionCount
    contexts = @($Candidate.contexts)
    lastSeenAt = [string]$Candidate.lastSeenAt
    status = $status
    rawPromptStored = $false
  }
}

function New-UserAdaptationV2StoreFromV1([string]$Root,[string]$WorkspaceRoot,[string]$MigrationId,[string]$SourceBindingHash,[string]$MigrationPayloadHash,[string]$MigrationTransitionId) {
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  $legacy = New-UserAdaptationStoreDefaults
  $state = if(Test-Path -LiteralPath $paths.state){Read-UserAdaptationJsonStrict $paths.state @('super-brain.user-adaptation-state.v1')}else{$null}
  $observations = if(Test-Path -LiteralPath $paths.observations){Read-UserAdaptationJsonStrict $paths.observations @('super-brain.user-adaptation-observations.v1')}else{$legacy.observations}
  $candidates = if(Test-Path -LiteralPath $paths.candidates){Read-UserAdaptationJsonStrict $paths.candidates @('super-brain.user-adaptation-candidates.v1')}else{$legacy.candidates}
  $profile = if(Test-Path -LiteralPath $paths.profile){Read-UserAdaptationJsonStrict $paths.profile @('super-brain.user-adaptation-profile.v1')}else{$legacy.profile}
  $tombstones = if(Test-Path -LiteralPath $paths.tombstones){Read-UserAdaptationJsonStrict $paths.tombstones @('super-brain.user-adaptation-tombstones.v1')}else{$legacy.tombstones}
  $now = (Get-Date).ToString('o')
  $convertedObservations = @($observations.items | ForEach-Object { ConvertTo-UserAdaptationV2Observation $Root $_ })
  $convertedCandidates = @($candidates.items | ForEach-Object { ConvertTo-UserAdaptationV2Candidate $Root $_ })
  $convertedProfile = @($profile.entries | ForEach-Object { ConvertTo-UserAdaptationV2ProfileEntry $Root $_ })
  $legacyHashes = @($tombstones.items | ForEach-Object { [string]$_.preferenceHash } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  foreach($entry in @($convertedProfile|Where-Object{@($legacyHashes)-contains(Get-UserAdaptationHash ([string]$_.preferenceId))})){$entry.status='forgotten'}
  $store = [pscustomobject]@{
    schema = 'super-brain.user-adaptation-store.v2'
    revision = 1
    generation = 1
    enabled = if($state){[bool]$state.enabled}else{$true}
    policyHash = Get-UserAdaptationPolicyHash $Root
    migrationId = $MigrationId
    migrationTransitionId = $MigrationTransitionId
    migrationPayloadHash = $MigrationPayloadHash
    sourceBindingHash = $SourceBindingHash
    migrationComplete = $true
    migratedFrom = 'v1'
    migratedAt = $now
    updatedAt = $now
    observations = @($convertedObservations)
    candidates = @($convertedCandidates)
    profile = @($convertedProfile)
    tombstones = @()
    legacyPreferenceHashes = @($legacyHashes)
    receipts = @()
    profilePressure = [string]$profile.profilePressure
    rawPromptStored = $false
  }
  $null = Add-UserAdaptationReceipt $Root $store 'migration' $MigrationTransitionId $MigrationPayloadHash 0 1
  return $store
}

function Get-UserAdaptationV2Store([string]$Root,[string]$WorkspaceRoot='',[switch]$AllowMissing) {
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  if (-not (Test-Path -LiteralPath $paths.storeV2 -PathType Leaf)) {
    if ($AllowMissing) { return $null }
    throw 'USER_ADAPTATION_V2_STORE_MISSING'
  }
  $store = Read-UserAdaptationJsonStrict $paths.storeV2 @('super-brain.user-adaptation-store.v2')
  if ([int]$store.revision -lt 1 -or [int]$store.generation -lt 1) { throw 'USER_ADAPTATION_V2_STORE_REVISION_INVALID' }
  return $store
}

function Get-UserAdaptationPayloadHash($Value) {
  return Get-UserAdaptationHash ($Value | ConvertTo-Json -Depth 20 -Compress) 32
}

function Get-UserAdaptationReplay($Store,[string]$Kind,[string]$TransitionId,[string]$PayloadHash) {
  if ([string]::IsNullOrWhiteSpace($TransitionId)) { return $null }
  $matches = @($Store.receipts | Where-Object { [string]$_.transitionId -eq $TransitionId })
  if ($matches.Count -eq 0) { return $null }
  $receipt = $matches[-1]
  if ([string]$receipt.kind -ne $Kind -or [string](Get-UserAdaptationProperty $receipt 'payloadHash' '') -ne $PayloadHash) { throw 'USER_ADAPTATION_TRANSITION_ID_CONFLICT' }
  return $receipt
}

function Test-UserAdaptationLifecycleStatus([string]$Status,[switch]$AllowEmpty) {
  if ($AllowEmpty -and [string]::IsNullOrWhiteSpace($Status)) { return $true }
  return ([string]$Status -in @('candidate','validated','staged','active','conflicted','dormant','superseded','forgotten','reinstated'))
}

function ConvertTo-UserAdaptationLifecycleChanges([object[]]$Changes,[int]$MaxChanges=8) {
  $result = @()
  foreach ($change in @($Changes)) {
    if ($null -eq $change) { continue }
    $entityType = ([string]$change.entityType).Trim().ToLowerInvariant()
    $entityId = ([string]$change.entityId).Trim().ToLowerInvariant()
    $fromStatus = ([string]$change.fromStatus).Trim().ToLowerInvariant()
    $toStatus = ([string]$change.toStatus).Trim().ToLowerInvariant()
    $reasonCode = ([string]$change.reasonCode).Trim().ToLowerInvariant()
    $scope = ([string]$change.scope).Trim().ToLowerInvariant()
    if ($entityType -notin @('candidate','preference','identity') -or $entityId -notmatch '^(candidate|pref|identity)-[a-f0-9]{16}$' -or -not (Test-UserAdaptationLifecycleStatus $fromStatus -AllowEmpty) -or -not (Test-UserAdaptationLifecycleStatus $toStatus -AllowEmpty) -or $reasonCode -notin @('synthesis','verified_correction','forget','reinstate','confidence_decay') -or $scope -notin @('global','project','workflow')) {
      throw 'USER_ADAPTATION_LIFECYCLE_CHANGE_INVALID'
    }
    if ($fromStatus -eq $toStatus) { continue }
    $result += [pscustomobject]@{entityType=$entityType;entityId=$entityId;fromStatus=$fromStatus;toStatus=$toStatus;reasonCode=$reasonCode;scope=$scope}
  }
  $result = @($result | Group-Object { "$($_.entityType)|$($_.entityId)|$($_.fromStatus)|$($_.toStatus)|$($_.reasonCode)|$($_.scope)" } | Sort-Object Name | ForEach-Object { $_.Group[0] })
  if ($result.Count -gt $MaxChanges) { $result = @($result | Select-Object -First $MaxChanges) }
  return @($result)
}

function Get-UserAdaptationLifecycleEntityMap([object[]]$Candidates,[object[]]$Profile) {
  $map = @{}
  foreach ($candidate in @($Candidates)) {
    $id = ([string](Get-UserAdaptationProperty $candidate 'candidateId' '')).ToLowerInvariant()
    if ($id -match '^candidate-[a-f0-9]{8}$') {
      $map['candidate|' + $id] = [pscustomobject]@{entityType='candidate';entityId=$id;status=([string](Get-UserAdaptationProperty $candidate 'status' '')).ToLowerInvariant();scope=([string](Get-UserAdaptationProperty $candidate 'scope' '')).ToLowerInvariant()}
    }
  }
  foreach ($entry in @($Profile)) {
    $id = ([string](Get-UserAdaptationProperty $entry 'preferenceId' '')).ToLowerInvariant()
    if ($id -match '^pref-[a-f0-9]{8}$') {
      $map['preference|' + $id] = [pscustomobject]@{entityType='preference';entityId=$id;status=([string](Get-UserAdaptationProperty $entry 'status' '')).ToLowerInvariant();scope=([string](Get-UserAdaptationProperty $entry 'scope' '')).ToLowerInvariant()}
    }
  }
  return $map
}

function Get-UserAdaptationLifecycleChanges([object[]]$BeforeCandidates,[object[]]$BeforeProfile,[object[]]$AfterCandidates,[object[]]$AfterProfile,[string]$ReasonCode) {
  $before = Get-UserAdaptationLifecycleEntityMap $BeforeCandidates $BeforeProfile
  $after = Get-UserAdaptationLifecycleEntityMap $AfterCandidates $AfterProfile
  $changes = @()
  foreach ($key in @($after.Keys | Sort-Object)) {
    $current = $after[$key]
    $prior = if ($before.ContainsKey($key)) { $before[$key] } else { $null }
    $fromStatus = if ($prior) { [string]$prior.status } else { '' }
    if (-not $prior -or $fromStatus -ne [string]$current.status) {
      $changes += [pscustomobject]@{entityType=[string]$current.entityType;entityId=[string]$current.entityId;fromStatus=$fromStatus;toStatus=[string]$current.status;reasonCode=$ReasonCode;scope=[string]$current.scope}
    }
  }
  return @($changes)
}

function Add-UserAdaptationReceipt([string]$Root,$Store,[string]$Kind,[string]$TransitionId,[string]$PayloadHash,[int]$FromRevision,[int]$ToRevision,[string]$IdentityHash='',[string[]]$IdentityHashes=@(),[object[]]$LifecycleChanges=@()) {
  $policy = Get-UserAdaptationPolicy $Root
  $receipts = @($Store.receipts)
  if (-not [string]::IsNullOrWhiteSpace($TransitionId)) {
    $existing = @($receipts | Where-Object { [string]$_.transitionId -eq $TransitionId } | Select-Object -First 1)
    if ($existing.Count -gt 0) {
      if ([string]$existing[0].kind -ne $Kind -or [string](Get-UserAdaptationProperty $existing[0] 'payloadHash' '') -ne $PayloadHash) { throw 'USER_ADAPTATION_TRANSITION_ID_CONFLICT' }
      return $existing[0]
    }
  }
  $boundIdentities=@(@($IdentityHashes)+@($IdentityHash)|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{([string]$_).ToLowerInvariant()}|Sort-Object -Unique)
  $maxChanges = [int]$policy.evolution.history.maxChangesPerReceipt
  $changes = ConvertTo-UserAdaptationLifecycleChanges $LifecycleChanges $maxChanges
  $previousChainHash = if ($receipts.Count -gt 0 -and $receipts[-1].PSObject.Properties['chainHash']) { [string]$receipts[-1].chainHash } else { '' }
  $receipt = [pscustomobject]@{receiptId='receipt-'+(Get-UserAdaptationHash "$Kind|$TransitionId|$PayloadHash|$FromRevision|$ToRevision|$($boundIdentities-join',')" 8);kind=$Kind;transitionId=$TransitionId;payloadHash=$PayloadHash;identityHash=if($boundIdentities.Count-eq1){$boundIdentities[0]}else{''};identityHashes=@($boundIdentities);fromRevision=$FromRevision;toRevision=$ToRevision;recordedAt=(Get-Date).ToString('o');trustLevel='local_same_user_unattested';lifecycleChanges=@($changes);previousChainHash=$previousChainHash;chainHash='';rawPromptStored=$false}
  $chainPayload=[ordered]@{schema='super-brain.user-adaptation-receipt-chain.v1';receiptId=$receipt.receiptId;kind=$Kind;transitionId=$TransitionId;payloadHash=$PayloadHash;fromRevision=$FromRevision;toRevision=$ToRevision;identityHashes=@($boundIdentities);recordedAt=$receipt.recordedAt;trustLevel=$receipt.trustLevel;lifecycleChanges=@($changes);previousChainHash=$previousChainHash}
  $receipt.chainHash=Get-UserAdaptationHash ($chainPayload|ConvertTo-Json -Depth 12 -Compress) 32
  $Store.receipts = @(@($receipts) + @($receipt) | Select-Object -Last ([int]$policy.storage.maxReceipts))
  return $receipt
}

function Invoke-UserAdaptationMigrationApply {
  param([string]$Root,[string]$ExpectedMigrationId,[int]$ExpectedRevision=0,[string]$WorkspaceRoot='',[string]$TransitionId='',[ValidateSet('none','after_backup','before_publish','after_publish')][string]$FaultPoint='none')
  if ([string]::IsNullOrWhiteSpace($ExpectedMigrationId)) { throw 'USER_ADAPTATION_MIGRATION_ID_REQUIRED' }
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  New-Item -ItemType Directory -Force -Path $paths.directory | Out-Null
  return Invoke-SuperBrainFileLock $paths.coordination {
    $preview = Get-UserAdaptationMigrationPreview $Root $WorkspaceRoot
    if (-not $preview.ok -or -not $preview.applicable) { throw 'USER_ADAPTATION_MIGRATION_PREVIEW_BLOCKED' }
    if ([string]$preview.migrationId -ne $ExpectedMigrationId) { throw 'USER_ADAPTATION_MIGRATION_PREVIEW_STALE' }
    $sourceBindingHash = Get-UserAdaptationPayloadHash @($preview.files | Where-Object { $_.exists } | Sort-Object name | ForEach-Object { [ordered]@{name=$_.name;schema=$_.sourceSchema;sha256=$_.sha256} })
    $payloadHash = Get-UserAdaptationPayloadHash ([ordered]@{operation='migration';migrationId=$ExpectedMigrationId;sourceBindingHash=$sourceBindingHash;policyHash=$preview.policyHash})
    $existing = Get-UserAdaptationV2Store $Root $WorkspaceRoot -AllowMissing
    if ($existing) {
      if ($existing.migrationComplete -eq $true -and [string]$existing.migrationId -eq $ExpectedMigrationId -and [string]$existing.sourceBindingHash -eq $sourceBindingHash -and [string]$existing.migrationPayloadHash -eq $payloadHash -and ([string]::IsNullOrWhiteSpace($TransitionId) -or [string]$existing.migrationTransitionId -eq $TransitionId)) { return [pscustomobject]@{ok=$true;action='MigrateApply';replayed=$true;migrationId=$ExpectedMigrationId;revision=[int]$existing.revision;rawPromptStored=$false} }
      throw 'USER_ADAPTATION_V2_STORE_ALREADY_EXISTS'
    }
    if ($ExpectedRevision -ne 0) { throw "USER_ADAPTATION_REVISION_MISMATCH expected=$ExpectedRevision actual=0" }
    $backupRoot = Join-Path $paths.migration "$ExpectedMigrationId\backup"
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $backupEntries = New-Object Collections.ArrayList
    foreach ($name in @('state','observations','candidates','profile','tombstones')) {
      $sourcePath = $paths.$name
      if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
      $destination = Join-Path $backupRoot ([IO.Path]::GetFileName($sourcePath))
      Copy-Item -LiteralPath $sourcePath -Destination $destination -Force -ErrorAction Stop
      $sourceHash=Get-SuperBrainFileSha256 $sourcePath;$backupHash=Get-SuperBrainFileSha256 $destination
      if([string]::IsNullOrWhiteSpace($sourceHash)-or[string]::IsNullOrWhiteSpace($backupHash)){throw'USER_ADAPTATION_MIGRATION_BACKUP_HASH_MISSING'}
      [void]$backupEntries.Add([pscustomobject]@{name=$name;sha256=$sourceHash;backupSha256=$backupHash;rawValueStored=$true})
    }
    if (@($backupEntries | Where-Object { $_.sha256 -ne $_.backupSha256 }).Count -gt 0) { throw 'USER_ADAPTATION_MIGRATION_BACKUP_HASH_MISMATCH' }
    $manifest = [pscustomobject]@{schema='super-brain.user-adaptation-migration-backup.v2';migrationId=$ExpectedMigrationId;createdAt=(Get-Date).ToString('o');entries=@($backupEntries);rawPromptStored=$false;privateBackup=$true}
    $migrationRoot=Split-Path -Parent $backupRoot;Write-UserAdaptationJson (Join-Path $migrationRoot 'manifest.json') $manifest 10
    $candidatePath="$($paths.storeV2).candidate.$PID.$([guid]::NewGuid().ToString('n'))";$publishedHash=''
    try {
      if($FaultPoint-eq'after_backup'){throw'USER_ADAPTATION_FAULT_AFTER_BACKUP'}
      $store = New-UserAdaptationV2StoreFromV1 $Root $WorkspaceRoot $ExpectedMigrationId $sourceBindingHash $payloadHash $TransitionId
      Write-UserAdaptationJson $candidatePath $store 30 -Compact
      $candidate=Read-UserAdaptationJsonStrict $candidatePath @('super-brain.user-adaptation-store.v2');$candidateHash=Get-SuperBrainFileSha256 $candidatePath
      if([string]::IsNullOrWhiteSpace($candidateHash)-or$candidate.migrationComplete-ne$true-or[string]$candidate.sourceBindingHash-ne$sourceBindingHash-or[string]$candidate.policyHash-ne[string]$preview.policyHash-or@($candidate.profile).Count-ne[int]$preview.preservedProfileEntryCount){throw'USER_ADAPTATION_MIGRATION_CANDIDATE_INVALID'}
      if($FaultPoint-eq'before_publish'){throw'USER_ADAPTATION_FAULT_BEFORE_PUBLISH'}
      Move-Item -LiteralPath $candidatePath -Destination $paths.storeV2 -Force -ErrorAction Stop;$publishedHash=Get-SuperBrainFileSha256 $paths.storeV2
      if($publishedHash-ne$candidateHash){throw'USER_ADAPTATION_MIGRATION_PUBLISH_HASH_MISMATCH'}
      if($FaultPoint-eq'after_publish'){throw'USER_ADAPTATION_FAULT_AFTER_PUBLISH'}
      $written = Get-UserAdaptationV2Store $Root $WorkspaceRoot
      return [pscustomobject]@{ok=$true;action='MigrateApply';replayed=$false;migrationId=$ExpectedMigrationId;revision=[int]$written.revision;generation=[int]$written.generation;profileEntryCount=@($written.profile).Count;backupEntryCount=$backupEntries.Count;rawPromptStored=$false;privateValuesReturned=$false}
    } catch {
      if(Test-Path -LiteralPath $candidatePath){Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue}
      if(-not[string]::IsNullOrWhiteSpace($publishedHash)-and(Test-Path -LiteralPath $paths.storeV2)-and(Get-SuperBrainFileSha256 $paths.storeV2)-eq$publishedHash){Move-Item -LiteralPath $paths.storeV2 -Destination (Join-Path $migrationRoot ("failed-store-"+$publishedHash+'.json')) -Force -ErrorAction SilentlyContinue}
      $rollback=[pscustomobject]@{schema='super-brain.user-adaptation-rollback-receipt.v2';migrationId=$ExpectedMigrationId;sourceBindingHash=$sourceBindingHash;publishedHash=$publishedHash;v1Preserved=$true;recordedAt=(Get-Date).ToString('o');rawPromptStored=$false}
      Write-UserAdaptationJson (Join-Path $migrationRoot 'rollback-receipt.json') $rollback 8
      throw
    }
  } 10000 120
}

function Get-UserAdaptationIdentityGeneration($Store,[string]$IdentityHash) {
  $tombstone = @($Store.tombstones | Where-Object { [string]$_.identityHash -eq $IdentityHash } | Select-Object -First 1)
  if ($tombstone.Count -eq 0) { return [pscustomobject]@{current=1;forgottenThrough=0;blocked=$false} }
  $forgotten = [int](Get-UserAdaptationProperty $tombstone[0] 'forgottenThroughGeneration' 0)
  $current = [int](Get-UserAdaptationProperty $tombstone[0] 'currentGeneration' $forgotten)
  return [pscustomobject]@{current=$current;forgottenThrough=$forgotten;blocked=($current -le $forgotten)}
}

function Get-UserAdaptationMedian([double[]]$Values) {
  $sorted = @($Values | Sort-Object)
  if ($sorted.Count -eq 0) { return 0.0 }
  $middle = [int][Math]::Floor($sorted.Count / 2)
  if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
  return ([double]$sorted[$middle-1] + [double]$sorted[$middle]) / 2.0
}

function Get-UserAdaptationMedianAbsoluteDeviation([double[]]$Values) {
  if (@($Values).Count -eq 0) { return 0.0 }
  $median = Get-UserAdaptationMedian $Values
  return Get-UserAdaptationMedian @($Values | ForEach-Object { [Math]::Abs([double]$_ - $median) })
}

function Get-UserAdaptationRenderedDirective([string]$Root,$Policy,$Entry) {
  $rule = Get-UserAdaptationHabitRule $Policy ([string]$Entry.habitKey) ([string]$Entry.value)
  $habit = $Policy.habits.PSObject.Properties[[string]$Entry.habitKey].Value
  $valueKind = [string](Get-UserAdaptationProperty $Entry 'valueKind' 'enum')
  if ($valueKind -ne 'bounded_parameters') { return $rule.directive }
  $rawValue = $habit.values.PSObject.Properties[[string]$Entry.value].Value
  $template = [string](Get-UserAdaptationProperty $rawValue 'directiveTemplate' '')
  if ([string]::IsNullOrWhiteSpace($template)) { throw 'USER_ADAPTATION_DIRECTIVE_TEMPLATE_INVALID' }
  $typed = ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey ([string]$Entry.habitKey) -Value ([string]$Entry.value) -Parameters $Entry.parameters
  if ([string](Get-UserAdaptationProperty $Entry 'parameterHash' '') -ne [string]$typed.parameterHash) { throw 'USER_ADAPTATION_PARAMETER_HASH_MISMATCH' }
  foreach ($property in @($typed.parameters.PSObject.Properties)) { $template = $template.Replace('{' + $property.Name + '}',[string]$property.Value) }
  if ($template -match '\{[A-Za-z][A-Za-z0-9]*\}') { throw 'USER_ADAPTATION_DIRECTIVE_TEMPLATE_UNRESOLVED' }
  return $template
}

function Add-UserAdaptationObservationV2 {
  param(
    [string]$Root,[string]$HabitKey,[string]$Value,[string]$Signal,[string]$Source,[string]$Scope,[string]$ScopeKey,[string]$Context,[string]$TaskId,[string]$EvidenceRef,[string]$WorkspaceRoot,
    $Parameters=$null,[string]$EvidenceKind='auto',[string]$Producer='auto',[string]$EvidenceDate='',[int]$ExpectedRevision=-1,[string]$TransitionId='',
    [string]$CorrectionCandidateId='',[string]$CorrectionCandidateHash='',[string]$VerificationArtifactPath='',[string]$VerificationHash='',[string]$CorrectionTargetPreferenceId='',
    $WorkingStore=$null,[switch]$DeferCommit
  )
  $policy = Get-UserAdaptationPolicy $Root
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  $typed = ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey $HabitKey -Value $Value -Parameters $Parameters
  $resolvedScopeKey = Resolve-UserAdaptationScopeKey $Scope $ScopeKey
  if (@($policy.contexts) -notcontains $Context) { throw 'USER_ADAPTATION_CONTEXT_INVALID' }
  $identity = Get-UserAdaptationIdentity $Scope $resolvedScopeKey $HabitKey
  $mapped = Get-UserAdaptationEvidenceKind $Source
  if ($Source -eq 'repeated_behavior') { $mapped = [pscustomobject]@{kind='task_instruction';producer='current_task_choice';promotionEligible=$false} }
  $kind = if($EvidenceKind -eq 'auto'){$mapped.kind}else{$EvidenceKind}
  $kindProperty = $policy.evidenceKinds.PSObject.Properties[$kind]
  if (-not $kindProperty) { throw 'USER_ADAPTATION_EVIDENCE_KIND_INVALID' }
  $producerValue = if($Producer -eq 'auto'){[string]$kindProperty.Value.producer}else{$Producer}
  if ($producerValue -ne [string]$kindProperty.Value.producer) { throw 'USER_ADAPTATION_PRODUCER_MISMATCH' }
  $allowedSourceEvidence = switch ($Source) {
    'explicit_user' { @('durable_explicit|trusted_direct_statement') }
    'repeated_behavior' { @('task_instruction|current_task_choice') }
    'accepted_outcome' { @('verified_outcome|task_verification','workflow_measurement|verified_task_protocol') }
    'user_correction' { @('verified_correction|closed_correction') }
    default { @() }
  }
  if (@($allowedSourceEvidence) -notcontains "$kind|$producerValue") { throw 'USER_ADAPTATION_SOURCE_EVIDENCE_MISMATCH' }
  $promotionEligible = [bool]$mapped.promotionEligible
  if ($kind -eq 'task_instruction') { $promotionEligible = $false }
  $safeTaskId = (([string]$TaskId -replace '[^A-Za-z0-9._-]+','-').Trim('-'))
  if ($safeTaskId.Length -gt 120) { $safeTaskId = $safeTaskId.Substring(0,120) }
  $now = (Get-Date).ToString('o')
  $dateValue = if([string]::IsNullOrWhiteSpace($EvidenceDate)){(Get-Date).ToString('yyyy-MM-dd')}else{try{([datetime]$EvidenceDate).ToString('yyyy-MM-dd')}catch{throw 'USER_ADAPTATION_EVIDENCE_DATE_INVALID'}}
  if ([datetime]$dateValue -gt (Get-Date).Date.AddDays([int]$policy.promotion.maximumFutureEvidenceSkewDays)) { throw 'USER_ADAPTATION_EVIDENCE_DATE_FUTURE' }
  $payloadHash = Get-UserAdaptationPayloadHash ([ordered]@{operation='observation';habitKey=$typed.habitKey;value=$typed.value;parameterHash=$typed.parameterHash;signal=$Signal.ToLowerInvariant();source=$Source;evidenceKind=$kind;producer=$producerValue;scope=$Scope;scopeKey=$resolvedScopeKey;context=$Context;taskId=$safeTaskId;evidenceHash=(Get-UserAdaptationHash $EvidenceRef);evidenceDate=$dateValue;correctionCandidateId=$CorrectionCandidateId;correctionCandidateHash=$CorrectionCandidateHash;verificationHash=$VerificationHash;correctionTargetPreferenceId=$CorrectionTargetPreferenceId})
  $operation = {
    param($store,[bool]$deferCommit)
    if(-not$deferCommit){
      $replayed = Get-UserAdaptationReplay $store 'observation' $TransitionId $payloadHash
      if ($replayed) { return [pscustomobject]@{ok=$true;action='Observe';replayed=$true;duplicate=$true;revision=[int]$store.revision;transitionId=$TransitionId;receiptId=[string]$replayed.receiptId;rawPromptStored=$false} }
      if ($ExpectedRevision -lt 0) { throw 'USER_ADAPTATION_EXPECTED_REVISION_REQUIRED' }
      if ([int]$store.revision -ne $ExpectedRevision) { throw "USER_ADAPTATION_REVISION_MISMATCH expected=$ExpectedRevision actual=$([int]$store.revision)" }
    }
    $generation = Get-UserAdaptationIdentityGeneration $store $identity.hash
    if ($generation.blocked) { throw 'USER_ADAPTATION_REINSTATE_REQUIRED' }
    $verifiedArtifact = $null
    $verifiedOutcome = $null
    if ($kind -in @('verified_outcome','workflow_measurement','verified_correction')) {
      if ($VerificationHash -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace($VerificationArtifactPath)) { throw 'USER_ADAPTATION_VERIFICATION_ARTIFACT_REQUIRED' }
      $verificationRoot = Join-Path $paths.workspace 'runtime-state\user-adaptation-verifications'
      $verificationFull = [IO.Path]::GetFullPath($VerificationArtifactPath)
      $expectedVerificationName = (Get-SuperBrainCanonicalTaskToken $TaskId) + '--' + $VerificationHash + '.json'
      if (-not (Test-SuperBrainChildPath $verificationRoot $verificationFull) -or -not [string]::Equals([IO.Path]::GetFileName($verificationFull),$expectedVerificationName,[StringComparison]::OrdinalIgnoreCase) -or (Get-SuperBrainFileSha256 $verificationFull) -ne $VerificationHash) { throw 'USER_ADAPTATION_VERIFICATION_ARTIFACT_MISMATCH' }
      $verifiedArtifact = Read-UserAdaptationJsonStrict $verificationFull
      if ((Get-SuperBrainFileSha256 $verificationFull) -ne $VerificationHash) { throw 'USER_ADAPTATION_VERIFICATION_ARTIFACT_MISMATCH' }
      $boundWorkspaceKey = if($Scope-eq'project'){$resolvedScopeKey}elseif($Scope-eq'workflow'){($resolvedScopeKey -split ':',2)[0]}else{''}
      $expectedWorkflowKey = if($Scope-eq'workflow'){($resolvedScopeKey -split ':',2)[1]}else{''}
      $currentPackageVersion=[string](Get-SuperBrainManifest $Root).version
      $request = $verifiedArtifact.request
      $expectedSignal = "$($typed.habitKey)=$($typed.value)".ToLowerInvariant()
      $typedMeasurementContexts=@();$typedContextsProperty=$typed.parameters.PSObject.Properties['contexts'];if($typedContextsProperty){$typedMeasurementContexts=@($typedContextsProperty.Value)}
      $measurementContextSuffix=if($typedMeasurementContexts.Count-gt0){';contexts='+(@($typedMeasurementContexts|Sort-Object)-join',')}else{''}
      $expectedMeasurement = ("review_protocol=multi_pass;forwardpasses=$([int]$typed.parameters.forwardPasses);reversepasses=$([int]$typed.parameters.reversePasses);riskfloor=$([string]$typed.parameters.riskFloor)"+$measurementContextSuffix).ToLowerInvariant()
      $requestSignals = @($request.signals | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $requestMeasurements = @($request.measurements | ForEach-Object { (([string]$_).Trim() -replace '\s+','').ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $requestMatch = if($kind-eq'workflow_measurement'){$requestMeasurements-contains$expectedMeasurement}else{$requestSignals-contains$expectedSignal}
      $artifactIssues=New-Object Collections.Generic.List[string]
      if([string]::IsNullOrWhiteSpace($boundWorkspaceKey)){$artifactIssues.Add('workspace_scope_missing')}
      $artifactSchema=[string]$verifiedArtifact.schema
      if(($kind-eq'verified_correction'-and$artifactSchema-notin@('super-brain.user-adaptation-verification.v1','super-brain.user-adaptation-verification.v2'))-or($kind-ne'verified_correction'-and$artifactSchema-ne'super-brain.user-adaptation-verification.v2')){$artifactIssues.Add('schema')}
      if([string]$verifiedArtifact.source-ne'task-verification.ps1'){$artifactIssues.Add('source')}
      if([string]$verifiedArtifact.packageVersion-ne$currentPackageVersion){$artifactIssues.Add('package_version')}
      if($verifiedArtifact.eligibleForAdaptation-ne$true){$artifactIssues.Add('eligibility')}
      if($verifiedArtifact.rawPromptStored-ne$false-or$verifiedArtifact.rawSummaryStored-ne$false-or$request.rawPromptStored-ne$false){$artifactIssues.Add('privacy')}
      if([string]$verifiedArtifact.taskId-ne$TaskId){$artifactIssues.Add('task_id')}
      if([string]$verifiedArtifact.workspaceKey-ne$boundWorkspaceKey){$artifactIssues.Add('workspace_key')}
      if($verifiedArtifact.verification.ok-ne$true-or$verifiedArtifact.verification.taskScopedGuardOk-ne$true-or$verifiedArtifact.verification.realUserPathVerified-ne$true){$artifactIssues.Add('verification')}
      if($verifiedArtifact.completion.completed-ne$true-or[string]::IsNullOrWhiteSpace([string]$verifiedArtifact.completion.transactionId)){$artifactIssues.Add('completion')}
      if([string]$request.source-ne$Source){$artifactIssues.Add('request_source')}
      if([string]$request.context-ne$Context){$artifactIssues.Add('request_context')}
      if([string]$request.workflowKey-ne$expectedWorkflowKey){$artifactIssues.Add('request_workflow')}
      if(-not$requestMatch){$artifactIssues.Add('request_payload')}
      if($artifactSchema-eq'super-brain.user-adaptation-verification.v2'){
        $calculatedRequestHash=Get-SuperBrainStableHash ($request|ConvertTo-Json -Depth 8 -Compress) 64
        if([string]$verifiedArtifact.requestHash-ne$calculatedRequestHash){$artifactIssues.Add('request_hash')}
      }
      if($artifactIssues.Count-gt0){throw ('USER_ADAPTATION_VERIFICATION_ARTIFACT_INVALID issues='+($artifactIssues-join','))}
      $outcomeRelative = [string]$verifiedArtifact.verifiedOutcome.relativePath
      if([string]::IsNullOrWhiteSpace($outcomeRelative)-or[IO.Path]::IsPathRooted($outcomeRelative)-or$outcomeRelative-match'(^|[\\/])\.\.([\\/]|$)'-or[string]$verifiedArtifact.verifiedOutcome.sha256-notmatch'^[a-f0-9]{64}$'){throw 'USER_ADAPTATION_VERIFIED_OUTCOME_REQUIRED'}
      $outcomeRoot = Join-Path $paths.workspace 'runtime-state\user-adaptation-outcomes'
      $outcomeFull = [IO.Path]::GetFullPath((Join-Path $paths.workspace ($outcomeRelative-replace'/','\')))
      $expectedOutcomeName=(Get-SuperBrainCanonicalTaskToken $TaskId)+'--'+[string]$verifiedArtifact.verifiedOutcome.sha256+'.json'
      if(-not(Test-SuperBrainChildPath $outcomeRoot $outcomeFull)-or-not[string]::Equals([IO.Path]::GetFileName($outcomeFull),$expectedOutcomeName,[StringComparison]::OrdinalIgnoreCase)-or(Get-SuperBrainFileSha256 $outcomeFull)-ne[string]$verifiedArtifact.verifiedOutcome.sha256){throw 'USER_ADAPTATION_VERIFIED_OUTCOME_MISMATCH'}
      $verifiedOutcome = Read-UserAdaptationJsonStrict $outcomeFull
      if((Get-SuperBrainFileSha256 $outcomeFull)-ne[string]$verifiedArtifact.verifiedOutcome.sha256-or[string]$verifiedOutcome.schema-ne'super-brain.verified-task-outcome.v1'-or[string]$verifiedOutcome.source-ne'task-verification.ps1'-or[string]$verifiedOutcome.packageVersion-ne$currentPackageVersion-or[string]$verifiedOutcome.taskId-ne$TaskId-or[string]$verifiedOutcome.workspaceKey-ne$boundWorkspaceKey-or$verifiedOutcome.classification.verifiedRealWorldTask-ne$true-or$verifiedOutcome.verification.ok-ne$true-or$verifiedOutcome.verification.taskScopedGuardOk-ne$true-or$verifiedOutcome.verification.realUserPathVerified-ne$true-or$verifiedOutcome.verification.completedCheckpointVerified-ne$true-or$verifiedOutcome.verification.evidenceBindingCurrent-ne$true-or$verifiedOutcome.privacy.rawPromptStored-ne$false-or$verifiedOutcome.privacy.rawSummaryStored-ne$false){throw 'USER_ADAPTATION_VERIFIED_OUTCOME_INVALID'}
      if($kind-ne'verified_correction'){
        $receiptRef=$verifiedArtifact.confirmationReceipt
        if(-not$receiptRef-or[string]$receiptRef.relativePath-eq''-or[string]$receiptRef.sha256-notmatch'^[a-f0-9]{64}$'){throw 'USER_ADAPTATION_CONFIRMATION_RECEIPT_REQUIRED'}
        $confirmation=Get-UserAdaptationConfirmationReceipt -Root $Root -WorkspaceRoot $paths.workspace -ReceiptPath ([string]$receiptRef.relativePath) -ExpectedSha256 ([string]$receiptRef.sha256) -TaskId $TaskId -WorkspaceKey $boundWorkspaceKey
        if([string]$receiptRef.selectionHash-ne[string]$confirmation.selectionHash-or[string]$confirmation.context-ne$Context-or[string]$confirmation.scope-ne$Scope-or[string]$confirmation.workflowKey-ne$expectedWorkflowKey){throw 'USER_ADAPTATION_CONFIRMATION_BINDING_MISMATCH'}
        $receiptSignals=@($confirmation.signals|ForEach-Object{"$($_.habitKey)=$($_.value)"}|Sort-Object -Unique);$artifactSignals=@($requestSignals|Sort-Object -Unique)
        if(($receiptSignals|ConvertTo-Json -Compress)-ne($artifactSignals|ConvertTo-Json -Compress)){throw 'USER_ADAPTATION_CONFIRMATION_SIGNAL_MISMATCH'}
        if($kind-eq'workflow_measurement'){
          if(-not$confirmation.protocolBinding-or[int]$confirmation.protocolBinding.forwardPasses-ne[int]$typed.parameters.forwardPasses-or[int]$confirmation.protocolBinding.reversePasses-ne[int]$typed.parameters.reversePasses-or[string]$confirmation.protocolBinding.riskFloor-ne[string]$typed.parameters.riskFloor-or$requestMeasurements.Count-ne1){throw 'USER_ADAPTATION_CONFIRMATION_PROTOCOL_MISMATCH'}
          $receiptProtocolContexts=@();if($confirmation.protocolBinding.PSObject.Properties['contexts']){$receiptProtocolContexts=@($confirmation.protocolBinding.contexts|Sort-Object -Unique)};$typedProtocolContexts=@();if($typed.parameters.PSObject.Properties['contexts']){$typedProtocolContexts=@($typed.parameters.contexts|Sort-Object -Unique)}
          if(($receiptProtocolContexts|ConvertTo-Json -Compress)-ne($typedProtocolContexts|ConvertTo-Json -Compress)){throw 'USER_ADAPTATION_CONFIRMATION_PROTOCOL_CONTEXT_MISMATCH'}
        }elseif($requestMeasurements.Count-gt0-and-not$confirmation.protocolBinding){throw 'USER_ADAPTATION_CONFIRMATION_PROTOCOL_UNEXPECTED'}
      }
    }
    $correctionTarget = $null
    if ($kind -eq 'verified_correction') {
      if ($CorrectionCandidateId -notmatch '^correction-[a-z0-9_-]{1,100}$' -or $CorrectionCandidateHash -notmatch '^[a-f0-9]{64}$' -or $VerificationHash -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace($CorrectionTargetPreferenceId)) { throw 'USER_ADAPTATION_CORRECTION_EVIDENCE_REQUIRED' }
      $candidatePath = Join-Path $paths.workspace "reflection\correction-candidates\$($CorrectionCandidateId.ToLowerInvariant()).json"
      if ((Get-SuperBrainFileSha256 $candidatePath) -ne $CorrectionCandidateHash) { throw 'USER_ADAPTATION_CORRECTION_EVIDENCE_MISMATCH' }
      $candidateEvidence = Read-UserAdaptationJsonStrict $candidatePath
      $requestCandidateId=[string]$verifiedArtifact.request.correctionCandidateId;$requestTargetId=[string]$verifiedArtifact.request.correctionTargetPreferenceId
      $candidateWorkspaceOk=Test-SuperBrainWorkspaceKey ([string]$candidateEvidence.workspaceKey) $boundWorkspaceKey
      $candidateStatus=[string]$candidateEvidence.status
      $candidateLifecycleOk=($candidateStatus-in@('closing','closed')-and$(if($candidateStatus-eq'closing'){-not[string]::IsNullOrWhiteSpace([string]$candidateEvidence.closingAt)}else{-not[string]::IsNullOrWhiteSpace([string]$candidateEvidence.closedAt)}))
      $candidateValid=(
        [string]$candidateEvidence.schema -eq 'super-brain.correction-candidate.v1' -and
        [string]$candidateEvidence.candidateId -eq $CorrectionCandidateId.ToLowerInvariant() -and
        $candidateWorkspaceOk -and $candidateLifecycleOk -and
        $candidateEvidence.rawPromptStored -eq $false -and $candidateEvidence.durablePromotionAllowed -eq $true -and
        [string]$candidateEvidence.analysisSummaryHash -match '^[a-f0-9]{24}$' -and [string]$candidateEvidence.closureReason -eq 'verified_fix_outcome' -and
        $candidateEvidence.autonomyEvidenceLink -and
        $candidateEvidence.autonomyEvidenceLink.eligible -eq $true -and [string]$candidateEvidence.autonomyEvidenceLink.taskId -eq $TaskId -and
        [string]$candidateEvidence.autonomyEvidenceLink.verifiedOutcomeRecordId -eq [string]$verifiedArtifact.verifiedOutcome.recordId -and
        [string]$candidateEvidence.autonomyEvidenceLink.verifiedOutcomeSha256 -eq [string]$verifiedArtifact.verifiedOutcome.sha256 -and
        [string]$verifiedOutcome.correctionCandidateId -eq $CorrectionCandidateId.ToLowerInvariant() -and
        $requestCandidateId -eq $CorrectionCandidateId.ToLowerInvariant() -and $requestTargetId -eq $CorrectionTargetPreferenceId
      )
      if(-not$candidateValid){throw 'USER_ADAPTATION_CORRECTION_EVIDENCE_INVALID'}
      $correctionTarget = @($store.profile | Where-Object { [string]$_.preferenceId -eq $CorrectionTargetPreferenceId -and [string]$_.identityHash -eq $identity.hash -and [string]$_.status -eq 'active' } | Select-Object -First 1)
      if ($correctionTarget.Count -ne 1 -or [string]$correctionTarget[0].source -eq 'explicit_user' -or [int]$correctionTarget[0].identityGeneration -ne [int]$generation.current) { throw 'USER_ADAPTATION_CORRECTION_TARGET_INVALID' }
      $correctionTarget = $correctionTarget[0]
      if([string]$correctionTarget.value-eq[string]$typed.value-and[string]$correctionTarget.parameterHash-eq[string]$typed.parameterHash){throw 'USER_ADAPTATION_CORRECTION_REPLACEMENT_REQUIRED'}
    }
    $evidenceHash = Get-UserAdaptationHash $(if([string]::IsNullOrWhiteSpace($EvidenceRef)){"$Scope|$resolvedScopeKey|$HabitKey|$Value|$($typed.parameterHash)|$Signal|$safeTaskId|$Context|$kind"}else{$EvidenceRef})
    $duplicate = @($store.observations | Where-Object {
      ([string]$_.evidenceHash -eq $evidenceHash) -or
      (-not [string]::IsNullOrWhiteSpace($safeTaskId) -and [string]$_.taskId -eq $safeTaskId -and [string]$_.identityHash -eq $identity.hash -and [int]$_.identityGeneration -eq [int]$generation.current)
    }).Count -gt 0
    if ($duplicate) { return [pscustomobject]@{ok=$true;action='Observe';replayed=$false;duplicate=$true;observationId='';observationCount=@($store.observations).Count;revision=[int]$store.revision;habitKey=$HabitKey;value=$Value;scope=$Scope;scopeKey=$resolvedScopeKey;rawPromptStored=$false} }
    $observation = [pscustomobject]@{
      observationId='obs-'+(Get-UserAdaptationHash "$now|$evidenceHash|$([guid]::NewGuid().ToString('n'))" 8);identityHash=$identity.hash;identityGeneration=[int]$generation.current;recordedRevision=([int]$store.revision+1)
      habitKey=$typed.habitKey;value=$typed.value;valueKind=$typed.valueKind;parameters=$typed.parameters;parameterHash=$typed.parameterHash;signal=$Signal.ToLowerInvariant();source=$Source
      evidenceKind=$kind;producer=$producerValue;promotionEligible=[bool]$promotionEligible;scope=$Scope;scopeKey=$resolvedScopeKey;context=$Context;taskId=$safeTaskId;evidenceHash=$evidenceHash;evidenceDate=$dateValue;verificationHash=if($verifiedArtifact){$VerificationHash}else{''};recordedAt=$now
      correctionCandidateHash=if($correctionTarget){$CorrectionCandidateHash}else{''};correctionTargetPreferenceId=if($correctionTarget){[string]$correctionTarget.preferenceId}else{''};correctionTargetValue=if($correctionTarget){[string]$correctionTarget.value}else{''};correctionTargetParameterHash=if($correctionTarget){[string]$correctionTarget.parameterHash}else{''};correctionTargetGeneration=if($correctionTarget){[int]$correctionTarget.identityGeneration}else{0};rawPromptStored=$false
    }
    $correctionChanges = @()
    if($correctionTarget){
      $correctionChanges = @([pscustomobject]@{entityType='preference';entityId=[string]$correctionTarget.preferenceId;fromStatus=[string]$correctionTarget.status;toStatus='dormant';reasonCode='verified_correction';scope=[string]$correctionTarget.scope})
      $correctionTarget.status='dormant';$correctionTarget|Add-Member -NotePropertyName dormantReason -NotePropertyValue 'verified_correction' -Force;$correctionTarget.updatedAt=$now
    }
    $store.observations = @(@($store.observations) + @($observation) | Sort-Object recordedAt | Select-Object -Last ([int]$policy.storage.maxObservations))
    if($deferCommit){return [pscustomobject]@{ok=$true;action='Observe';replayed=$false;duplicate=$false;deferred=$true;observationId=$observation.observationId;observationCount=@($store.observations).Count;revision=[int]$store.revision;receiptId='';suppressedPreferenceId=if($correctionTarget){[string]$correctionTarget.preferenceId}else{''};habitKey=$HabitKey;value=$Value;scope=$Scope;scopeKey=$resolvedScopeKey;rawPromptStored=$false}}
    $fromRevision = [int]$store.revision
    $store.revision = $fromRevision + 1
    $store.updatedAt = $now
    $receipt = Add-UserAdaptationReceipt $Root $store 'observation' $TransitionId $payloadHash $fromRevision ([int]$store.revision) $identity.hash @() $correctionChanges
    Write-UserAdaptationJson $paths.storeV2 $store 30 -Compact
    return [pscustomobject]@{ok=$true;action='Observe';replayed=$false;duplicate=$false;observationId=$observation.observationId;observationCount=@($store.observations).Count;revision=[int]$store.revision;receiptId=$receipt.receiptId;suppressedPreferenceId=if($correctionTarget){[string]$correctionTarget.preferenceId}else{''};habitKey=$HabitKey;value=$Value;scope=$Scope;scopeKey=$resolvedScopeKey;rawPromptStored=$false}
  }
  if($null-ne$WorkingStore){
    if(-not$DeferCommit){throw 'USER_ADAPTATION_WORKING_STORE_REQUIRES_DEFERRED_COMMIT'}
    return & $operation $WorkingStore $true
  }
  if($DeferCommit){throw 'USER_ADAPTATION_DEFERRED_COMMIT_REQUIRES_WORKING_STORE'}
  return Invoke-SuperBrainFileLock $paths.coordination {
    $store = Get-UserAdaptationV2Store $Root $WorkspaceRoot
    return & $operation $store $false
  } 5000 120
}

function Add-UserAdaptationObservationBatchV2 {
  param(
    [string]$Root,[object[]]$Items,[string]$Source,[string]$Scope,[string]$ScopeKey,[string]$Context,[string]$TaskId,[string]$WorkspaceRoot,
    [int]$ExpectedRevision=-1,[string]$TransitionId='',[string]$CorrectionCandidateId='',[string]$CorrectionCandidateHash='',
    [string]$VerificationArtifactPath='',[string]$VerificationHash='',[string]$CorrectionTargetPreferenceId='',
    [ValidateSet('none','before_replace')][string]$FaultPoint='none'
  )
  $policy=Get-UserAdaptationPolicy $Root
  $paths=Get-UserAdaptationPaths $Root $WorkspaceRoot
  $members=@($Items)
  if($members.Count-lt1){throw 'USER_ADAPTATION_OBSERVATION_BATCH_REQUIRED'}
  if($members.Count-gt[int]$policy.verifiedOutcomeObservation.maxSignalsPerTask){throw 'USER_ADAPTATION_OBSERVER_SIGNAL_BUDGET_EXCEEDED'}
  if($ExpectedRevision-lt0){throw 'USER_ADAPTATION_EXPECTED_REVISION_REQUIRED'}
  if([string]::IsNullOrWhiteSpace($TransitionId)){throw 'USER_ADAPTATION_OBSERVATION_BATCH_TRANSITION_REQUIRED'}
  if($Source-notin@('accepted_outcome','user_correction')){throw 'USER_ADAPTATION_OBSERVATION_BATCH_SOURCE_INVALID'}
  if($Source-eq'user_correction'-and$members.Count-ne1){throw 'USER_ADAPTATION_OBSERVER_CORRECTION_SIGNAL_COUNT_INVALID'}
  $resolvedScopeKey=Resolve-UserAdaptationScopeKey $Scope $ScopeKey
  if(@($policy.contexts)-notcontains$Context){throw 'USER_ADAPTATION_CONTEXT_INVALID'}
  $normalized=New-Object Collections.ArrayList
  foreach($member in $members){
    $habitKey=[string](Get-UserAdaptationProperty $member 'habitKey' '')
    $value=[string](Get-UserAdaptationProperty $member 'value' '')
    $parameters=Get-UserAdaptationProperty $member 'parameters' $null
    $typed=ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey $habitKey -Value $value -Parameters $parameters
    $kind=if($Source-eq'user_correction'){'verified_correction'}elseif($typed.valueKind-eq'bounded_parameters'){'workflow_measurement'}else{'verified_outcome'}
    $kindProperty=$policy.evidenceKinds.PSObject.Properties[$kind]
    if(-not$kindProperty){throw 'USER_ADAPTATION_EVIDENCE_KIND_INVALID'}
    $producer=[string]$kindProperty.Value.producer
    $signal='Support'
    $descriptor="$($typed.habitKey)|$($typed.value)|$($typed.parameterHash)|$kind|$producer|$($signal.ToLowerInvariant())"
    [void]$normalized.Add([pscustomobject]@{habitKey=$typed.habitKey;value=$typed.value;parameters=$typed.parameters;parameterHash=$typed.parameterHash;evidenceKind=$kind;producer=$producer;signal=$signal;descriptor=$descriptor})
  }
  if(@($normalized.descriptor|Select-Object -Unique).Count-ne$normalized.Count){throw 'USER_ADAPTATION_OBSERVATION_BATCH_DUPLICATE_MEMBER'}
  $conflicts=@($normalized|Group-Object habitKey|Where-Object{@($_.Group|ForEach-Object{"$($_.value)|$($_.parameterHash)"}|Select-Object -Unique).Count-gt1})
  if($conflicts.Count-gt0){throw 'USER_ADAPTATION_OBSERVATION_BATCH_CONFLICT'}
  $verifiedMembers=@($normalized)
  if($verifiedMembers.Count-gt0){
    if($VerificationHash-notmatch'^[a-f0-9]{64}$'-or[string]::IsNullOrWhiteSpace($VerificationArtifactPath)){throw 'USER_ADAPTATION_VERIFICATION_ARTIFACT_REQUIRED'}
    $verificationFull=[IO.Path]::GetFullPath($VerificationArtifactPath)
    $verificationRoot=Join-Path $paths.workspace 'runtime-state\user-adaptation-verifications'
    $expectedName=(Get-SuperBrainCanonicalTaskToken $TaskId)+'--'+$VerificationHash+'.json'
    if(-not(Test-SuperBrainChildPath $verificationRoot $verificationFull)-or-not[string]::Equals([IO.Path]::GetFileName($verificationFull),$expectedName,[StringComparison]::OrdinalIgnoreCase)-or(Get-SuperBrainFileSha256 $verificationFull)-ne$VerificationHash){throw 'USER_ADAPTATION_VERIFICATION_ARTIFACT_MISMATCH'}
    $artifact=Read-UserAdaptationJsonStrict $verificationFull
    if((Get-SuperBrainFileSha256 $verificationFull)-ne$VerificationHash){throw 'USER_ADAPTATION_VERIFICATION_ARTIFACT_MISMATCH'}
    $dateValue=if([string]::IsNullOrWhiteSpace([string]$artifact.checkedAt)){(Get-Date).ToString('yyyy-MM-dd')}else{try{([datetime]$artifact.checkedAt).ToString('yyyy-MM-dd')}catch{throw 'USER_ADAPTATION_EVIDENCE_DATE_INVALID'}}
    if([datetime]$dateValue-gt(Get-Date).Date.AddDays([int]$policy.promotion.maximumFutureEvidenceSkewDays)){throw 'USER_ADAPTATION_EVIDENCE_DATE_FUTURE'}
    foreach($member in $normalized){$member|Add-Member -NotePropertyName evidenceRef -NotePropertyValue "verified-outcome|$TaskId|$resolvedScopeKey|$Context|$Source|$($member.habitKey)|$($member.value)|$VerificationHash" -Force;$member|Add-Member -NotePropertyName evidenceHash -NotePropertyValue (Get-UserAdaptationHash ([string]$member.evidenceRef)) -Force}
    $expectedSignals=@($normalized|Where-Object{$_.evidenceKind-ne'workflow_measurement'}|ForEach-Object{"$($_.habitKey)=$($_.value)".ToLowerInvariant()}|Sort-Object -Unique)
    $expectedMeasurements=@($normalized|Where-Object{$_.evidenceKind-eq'workflow_measurement'}|ForEach-Object{
      $contexts=@();if($_.parameters-and$_.parameters.PSObject.Properties['contexts']){$contexts=@($_.parameters.contexts|ForEach-Object{([string]$_).ToLowerInvariant()}|Sort-Object -Unique)}
      ("review_protocol=multi_pass;forwardpasses=$([int]$_.parameters.forwardPasses);reversepasses=$([int]$_.parameters.reversePasses);riskfloor=$([string]$_.parameters.riskFloor)"+$(if($contexts.Count-gt0){';contexts='+($contexts-join',')}else{''})).ToLowerInvariant()
    }|Sort-Object -Unique)
    $artifactSignals=@($artifact.request.signals|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
    $artifactMeasurements=@($artifact.request.measurements|ForEach-Object{(([string]$_).Trim()-replace'\s+','').ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
    if((ConvertTo-Json -InputObject @($expectedSignals) -Compress)-ne(ConvertTo-Json -InputObject @($artifactSignals) -Compress)-or(ConvertTo-Json -InputObject @($expectedMeasurements) -Compress)-ne(ConvertTo-Json -InputObject @($artifactMeasurements) -Compress)){throw 'USER_ADAPTATION_OBSERVATION_BATCH_EXACT_SET_MISMATCH'}
  }
  $canonicalMembers=@($normalized|Sort-Object descriptor|ForEach-Object{"$($_.descriptor)|evidence=$($_.evidenceHash)"})
  $identityHashes=@($normalized|ForEach-Object{(Get-UserAdaptationIdentity $Scope $resolvedScopeKey ([string]$_.habitKey)).hash}|Sort-Object -Unique)
  $payloadHash=Get-UserAdaptationPayloadHash ([ordered]@{operation='observation_batch';source=$Source;scope=$Scope;scopeKey=$resolvedScopeKey;context=$Context;taskId=$TaskId;verificationHash=$VerificationHash;evidenceDate=$dateValue;correctionCandidateId=$CorrectionCandidateId;correctionCandidateHash=$CorrectionCandidateHash;correctionTargetPreferenceId=$CorrectionTargetPreferenceId;members=$canonicalMembers;identityHashes=$identityHashes})
  return Invoke-SuperBrainFileLock $paths.coordination {
    $store=Get-UserAdaptationV2Store $Root $WorkspaceRoot
    $replayed=Get-UserAdaptationReplay $store 'observation_batch' $TransitionId $payloadHash
    if($replayed){return [pscustomobject]@{ok=$true;action='ObserveBatch';replayed=$true;appliedCount=0;duplicateCount=$normalized.Count;revision=[int]$store.revision;receiptId=[string]$replayed.receiptId;rawPromptStored=$false}}
    if([int]$store.revision-ne$ExpectedRevision){throw "USER_ADAPTATION_REVISION_MISMATCH expected=$ExpectedRevision actual=$([int]$store.revision)"}
    $workingStore=$store
    $results=@()
    foreach($member in @($normalized|Sort-Object descriptor)){
      $results+=Add-UserAdaptationObservationV2 -Root $Root -HabitKey $member.habitKey -Value $member.value -Signal $member.signal -Source $Source -Scope $Scope -ScopeKey $resolvedScopeKey -Context $Context -TaskId $TaskId -EvidenceRef ([string]$member.evidenceRef) -WorkspaceRoot $WorkspaceRoot -Parameters $member.parameters -EvidenceKind $member.evidenceKind -Producer $member.producer -EvidenceDate $dateValue -ExpectedRevision $ExpectedRevision -TransitionId '' -CorrectionCandidateId $CorrectionCandidateId -CorrectionCandidateHash $CorrectionCandidateHash -VerificationArtifactPath $VerificationArtifactPath -VerificationHash $VerificationHash -CorrectionTargetPreferenceId $CorrectionTargetPreferenceId -WorkingStore $workingStore -DeferCommit
    }
    $applied=@($results|Where-Object{$_.duplicate-ne$true})
    if($applied.Count-eq0){return [pscustomobject]@{ok=$true;action='ObserveBatch';replayed=$false;appliedCount=0;duplicateCount=$results.Count;revision=[int]$store.revision;receiptId='';observationIds=@();rawPromptStored=$false}}
    $fromRevision=[int]$store.revision
    $workingStore.revision=$fromRevision+1
    $workingStore.updatedAt=(Get-Date).ToString('o')
    $batchCorrectionChanges=@()
    foreach($preferenceId in @($applied.suppressedPreferenceId|Where-Object{$_}|Select-Object -Unique)){
      $entry=@($workingStore.profile|Where-Object{[string]$_.preferenceId-eq[string]$preferenceId}|Select-Object -First 1)
      if($entry.Count-eq1){$batchCorrectionChanges+=[pscustomobject]@{entityType='preference';entityId=[string]$entry[0].preferenceId;fromStatus='active';toStatus=[string]$entry[0].status;reasonCode='verified_correction';scope=[string]$entry[0].scope}}
    }
    $receipt=Add-UserAdaptationReceipt $Root $workingStore 'observation_batch' $TransitionId $payloadHash $fromRevision ([int]$workingStore.revision) '' $identityHashes $batchCorrectionChanges
    Write-UserAdaptationJsonLockHeld $paths.storeV2 $workingStore 30 $FaultPoint
    return [pscustomobject]@{ok=$true;action='ObserveBatch';replayed=$false;appliedCount=$applied.Count;duplicateCount=@($results|Where-Object{$_.duplicate-eq$true}).Count;revision=[int]$workingStore.revision;receiptId=$receipt.receiptId;observationIds=@($applied.observationId);suppressedPreferenceIds=@($applied.suppressedPreferenceId|Where-Object{$_}|Select-Object -Unique);rawPromptStored=$false}
  } 5000 120
}

function Invoke-UserAdaptationSynthesisV2 {
  param([string]$Root,[string]$WorkspaceRoot='',[int]$ExpectedRevision=-1,[string]$TransitionId='',[datetime]$Now=(Get-Date))
  $policy = Get-UserAdaptationPolicy $Root
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  $payloadHash = Get-UserAdaptationPayloadHash ([ordered]@{operation='synthesis';now=$Now.ToUniversalTime().ToString('o')})
  return Invoke-SuperBrainFileLock $paths.coordination {
    $store = Get-UserAdaptationV2Store $Root $WorkspaceRoot
    $replayed = Get-UserAdaptationReplay $store 'synthesis' $TransitionId $payloadHash
    if ($replayed) { return [pscustomobject]@{ok=$true;action='Synthesize';replayed=$true;revision=[int]$store.revision;receiptId=[string]$replayed.receiptId;rawPromptStored=$false} }
    if ($ExpectedRevision -lt 0) { throw 'USER_ADAPTATION_EXPECTED_REVISION_REQUIRED' }
    if ([int]$store.revision -ne $ExpectedRevision) { throw "USER_ADAPTATION_REVISION_MISMATCH expected=$ExpectedRevision actual=$([int]$store.revision)" }
    $beforeCandidates=if(@($store.candidates).Count-gt0){@($store.candidates|ConvertTo-Json -Depth 30|ConvertFrom-Json)}else{@()}
    $beforeProfile=if(@($store.profile).Count-gt0){@($store.profile|ConvertTo-Json -Depth 30|ConvertFrom-Json)}else{@()}
    $cutoff = $Now.AddDays(-[int]$policy.storage.observationRetentionDays)
    $observations = @($store.observations | Where-Object {
      if ([string]$_.evidenceKind -in @('durable_explicit','verified_correction')) { return $true }
      try { return ([datetime]$_.recordedAt -ge $cutoff) } catch { return $false }
    } | Sort-Object recordedAt | Select-Object -Last ([int]$policy.storage.maxObservations))
    $entries = @($store.profile)
    $previousCandidates = @($store.candidates)
    $candidates = New-Object Collections.ArrayList
    $promoted = New-Object Collections.ArrayList
    $suppressed = New-Object Collections.ArrayList

    foreach ($correction in @($observations | Where-Object { [string]$_.evidenceKind -eq 'verified_correction' })) {
      foreach ($entry in @($entries | Where-Object { [string]$_.preferenceId -eq [string]$correction.correctionTargetPreferenceId -and [int]$_.identityGeneration -eq [int]$correction.correctionTargetGeneration -and [string]$_.status -eq 'active' -and [string]$_.source -ne 'explicit_user' })) {
        $entry.status = 'dormant'; $entry | Add-Member -NotePropertyName dormantReason -NotePropertyValue 'verified_correction' -Force; $entry.updatedAt = $Now.ToString('o'); [void]$suppressed.Add([string]$entry.preferenceId)
      }
    }

    $eligibleSupport = @($observations | Where-Object {
      if ([string]$_.signal -ne 'support' -or $_.promotionEligible -ne $true) { return $false }
      $identityState = Get-UserAdaptationIdentityGeneration $store ([string]$_.identityHash)
      return (-not $identityState.blocked -and [int]$_.identityGeneration -eq [int]$identityState.current)
    })
    function Get-SynthesisSupportGroupKey($Observation,[bool]$ExactParameters) {
      if($ExactParameters-or[string]$Observation.valueKind-ne'bounded_parameters'){return "$([string]$Observation.value)|$([string]$Observation.parameterHash)"}
      $parameterContexts=@();if($Observation.parameters-and$Observation.parameters.PSObject.Properties['contexts']){$parameterContexts=@($Observation.parameters.contexts|ForEach-Object{([string]$_).ToLowerInvariant()}|Sort-Object -Unique)}
      return "$([string]$Observation.value)|risk=$([string]$Observation.parameters.riskFloor)|contexts=$($parameterContexts-join',')"
    }
    foreach ($identityGroup in @($eligibleSupport | Group-Object identityHash)) {
      $identityObservations = @($identityGroup.Group)
      $identityHasExplicit=@($identityObservations|Where-Object{[string]$_.evidenceKind-eq'durable_explicit'-and[string]$_.producer-eq'trusted_direct_statement'}).Count-gt0
      $supportGroups = @($identityObservations | Group-Object { Get-SynthesisSupportGroupKey $_ $identityHasExplicit })
      $identityCandidates = New-Object Collections.ArrayList
      foreach ($group in $supportGroups) {
        $support = @($group.Group)
        $first = $support[0]
        $explicit = @($support | Where-Object { [string]$_.evidenceKind -eq 'durable_explicit' -and [string]$_.producer -eq 'trusted_direct_statement' }).Count -gt 0
        $typed = ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey ([string]$first.habitKey) -Value ([string]$first.value) -Parameters $first.parameters
        $modeSupportCount=$support.Count
        if(-not$explicit-and$typed.valueKind-eq'bounded_parameters'){
          $numericGroups=@($support|Group-Object{"$([int]$_.parameters.forwardPasses)|$([int]$_.parameters.reversePasses)"}|Sort-Object @{Expression='Count';Descending=$true},@{Expression='Name';Descending=$false})
          $modeGroup=$numericGroups[0];$modeObservation=$modeGroup.Group[0];$modeParameters=[ordered]@{forwardPasses=[int]$modeObservation.parameters.forwardPasses;reversePasses=[int]$modeObservation.parameters.reversePasses;riskFloor=[string]$modeObservation.parameters.riskFloor}
          if($modeObservation.parameters.PSObject.Properties['contexts']){$modeParameters.contexts=@($modeObservation.parameters.contexts|ForEach-Object{([string]$_).ToLowerInvariant()}|Sort-Object -Unique)}
          $typed=ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey ([string]$first.habitKey) -Value ([string]$first.value) -Parameters ([pscustomobject]$modeParameters)
          $modeSupportCount=[int]$modeGroup.Count
        }
        $directContradictions = @($observations | Where-Object { [string]$_.identityHash -eq [string]$first.identityHash -and [int]$_.identityGeneration-eq[int]$first.identityGeneration -and [string]$_.signal -eq 'contradict' }).Count
        $competingSupport = @($identityObservations | Where-Object { (Get-SynthesisSupportGroupKey $_ $identityHasExplicit) -ne [string]$group.Name }).Count
        $contradictions = $directContradictions + $competingSupport
        $taskIds = @($support.taskId | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        $contexts = @($support.context | Select-Object -Unique)
        $dates = @($support.evidenceDate | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        $confidence = if($explicit){[double]$policy.promotion.explicitUserConfidence}else{[double]$policy.promotion.inferredBaseConfidence + ([double]$policy.promotion.distinctTaskIncrement*$taskIds.Count) + ([double]$policy.promotion.distinctContextIncrement*$contexts.Count) - ([double]$policy.promotion.contradictionPenalty*$contradictions)}
        $confidence = [Math]::Round([Math]::Max(0.0,[Math]::Min($confidence,0.99)),4)
        $modeShare = if($support.Count -gt 0){[double]$modeSupportCount/[double]$support.Count}else{0.0}
        $mad = 0.0
        if ($typed.valueKind -eq 'bounded_parameters') {
          $forward = @($support | ForEach-Object { [double]$_.parameters.forwardPasses })
          $reverse = @($support | ForEach-Object { [double]$_.parameters.reversePasses })
          $mad = [Math]::Max((Get-UserAdaptationMedianAbsoluteDeviation $forward),(Get-UserAdaptationMedianAbsoluteDeviation $reverse))
        }
        $eligible = if($explicit){$true}elseif($typed.valueKind -eq 'bounded_parameters'){
          $support.Count -ge [int]$policy.promotion.parameterizedMinimumDistinctTasks -and $taskIds.Count -ge [int]$policy.promotion.parameterizedMinimumDistinctTasks -and $dates.Count -ge [int]$policy.promotion.parameterizedMinimumDistinctDates -and $contexts.Count -ge [int]$policy.promotion.minimumDistinctContexts -and $modeShare -ge [double]$policy.promotion.parameterizedMinimumModeShare -and $mad -le [double]$policy.promotion.parameterizedMaximumMedianAbsoluteDeviation -and $contradictions -le [int]$policy.promotion.maximumContradictions -and $confidence -ge [double]$policy.promotion.minimumConfidence
        }else{
          $support.Count -ge [int]$policy.promotion.minimumSupport -and $taskIds.Count -ge [int]$policy.promotion.minimumDistinctTasks -and $dates.Count -ge [int]$policy.promotion.minimumDistinctDates -and $contexts.Count -ge [int]$policy.promotion.minimumDistinctContexts -and $contradictions -le [int]$policy.promotion.maximumContradictions -and $confidence -ge [double]$policy.promotion.minimumConfidence
        }
        $candidateKey = "$([string]$first.identityHash)|$([string]$first.value)|$([string]$typed.parameterHash)|$([int]$first.identityGeneration)"
        $candidateId = 'candidate-' + (Get-UserAdaptationHash $candidateKey 8)
        $preferenceId = 'pref-' + (Get-UserAdaptationHash $candidateKey 8)
        $previous = @($previousCandidates | Where-Object { [string]$_.candidateId -eq $candidateId } | Select-Object -First 1)
        $highAuthorityGlobal = ([string]$first.scope -eq 'global' -and [string]$first.habitKey -eq 'review_protocol' -and $policy.promotion.globalHighAuthorityRequiresExplicit -eq $true)
        $status = 'candidate'
        if ($explicit) { $status = 'active' }
        elseif ($eligible) {
          $alreadyActive = @($entries | Where-Object { [string]$_.identityHash -eq [string]$first.identityHash -and [string]$_.value -eq [string]$first.value -and [string](Get-UserAdaptationProperty $_ 'parameterHash' (Get-UserAdaptationHash '{}')) -eq [string]$typed.parameterHash -and [string]$_.status -eq 'active' }).Count -gt 0
          if ($alreadyActive) { $status = 'active' }
          elseif (-not $highAuthorityGlobal -and $previous.Count -gt 0 -and [string]$previous[0].status -eq 'staged' -and $support.Count -gt [int]$previous[0].supportCount) { $status = 'active' }
          else { $status = 'staged' }
        }
        $legacyPreferenceId = 'pref-' + (Get-UserAdaptationHash "$([string]$first.scope)|$([string]$first.scopeKey)|$([string]$first.habitKey)|$([string]$first.value)" 8)
        if (@($store.legacyPreferenceHashes) -contains (Get-UserAdaptationHash $legacyPreferenceId)) { $status = 'forgotten' }
        $latestObservationRevision=[int](@($support|ForEach-Object{[int](Get-UserAdaptationProperty $_ 'recordedRevision' 0)}|Measure-Object -Maximum).Maximum)
        $validationStatus = if ($explicit) { 'explicit_user' } elseif ($eligible) { 'validated' } else { 'pending' }
        $validation = [pscustomobject]@{
          status = $validationStatus
          scopedEvidence = $true
          minimumSupportMet = [bool]$eligible
          distinctTasksMet = ($taskIds.Count -ge [int]$policy.promotion.minimumDistinctTasks)
          distinctContextsMet = ($contexts.Count -ge [int]$policy.promotion.minimumDistinctContexts)
          contradictionGuardMet = ($contradictions -le [int]$policy.promotion.maximumContradictions)
          confidenceGuardMet = ($confidence -ge [double]$policy.promotion.minimumConfidence)
          overfitGuardPassed = (-not $explicit -and $eligible)
          validatedAt = if ($eligible) { [string](@($support|Sort-Object recordedAt -Descending|Select-Object -First 1).recordedAt) } else { '' }
          rawPromptStored = $false
        }
        $candidate = [pscustomobject]@{
          candidateId=$candidateId;preferenceId=$preferenceId;identityHash=[string]$first.identityHash;identityGeneration=[int]$first.identityGeneration;scope=[string]$first.scope;scopeKey=[string]$first.scopeKey;habitKey=$typed.habitKey;value=$typed.value;valueKind=$typed.valueKind;parameters=$typed.parameters;parameterHash=$typed.parameterHash
          source=if($explicit){'explicit_user'}else{'inferred'};baseConfidence=$confidence;confidence=$confidence;supportCount=$support.Count;modeSupportCount=$modeSupportCount;distinctTaskCount=$taskIds.Count;distinctContextCount=$contexts.Count;distinctDateCount=$dates.Count;contradictionCount=$contradictions;modeShare=[Math]::Round($modeShare,4);medianAbsoluteDeviation=[Math]::Round($mad,4);contexts=$contexts;latestObservationRevision=$latestObservationRevision;lastSeenAt=[string](@($support|Sort-Object recordedAt -Descending|Select-Object -First 1).recordedAt);status=$status;validation=$validation;rawPromptStored=$false
        }
        [void]$identityCandidates.Add($candidate)
      }
      if ($supportGroups.Count -gt 1) {
        $durable = @($identityCandidates | Where-Object { [string]$_.source -eq 'explicit_user' } | Sort-Object @{Expression={[int](Get-UserAdaptationProperty $_ 'latestObservationRevision' 0)};Descending=$true},@{Expression='lastSeenAt';Descending=$true})
        $latestDurable=@()
        if($durable.Count-gt0){
          $latestRevision=[int](Get-UserAdaptationProperty $durable[0] 'latestObservationRevision' 0)
          $latestDurable=if($latestRevision-gt0){@($durable[0])}else{@($durable|Where-Object{[string]$_.lastSeenAt-eq[string]$durable[0].lastSeenAt})}
        }
        if (@($latestDurable).Count -eq 1) {
          $latestDurableValue=@($latestDurable)[0]
          $latestDurableValue.status='active'
          foreach($candidate in @($identityCandidates | Where-Object { $_.candidateId -ne $latestDurableValue.candidateId })){$candidate.status=if([string]$candidate.source-eq'explicit_user'){'superseded'}else{'conflicted'}}
        } else {
          foreach($candidate in @($identityCandidates)){$candidate.status='conflicted'}
          foreach($entry in @($entries|Where-Object{[string]$_.identityHash -eq [string]$identityGroup.Name -and [string]$_.status -eq 'active' -and [string]$_.source -ne 'explicit_user'})){$entry.status='dormant';$entry|Add-Member -NotePropertyName dormantReason -NotePropertyValue 'competing_evidence' -Force;$entry.updatedAt=$Now.ToString('o');[void]$suppressed.Add([string]$entry.preferenceId)}
        }
      }
      foreach($candidate in @($identityCandidates)){[void]$candidates.Add($candidate)}
      $winner = @($identityCandidates | Where-Object { [string]$_.status -eq 'active' } | Sort-Object @{Expression={if($_.source-eq'explicit_user'){1}else{0}};Descending=$true}, @{Expression='confidence';Descending=$true}, @{Expression='supportCount';Descending=$true}, @{Expression='lastSeenAt';Descending=$true} | Select-Object -First 1)
      if ($winner.Count -eq 0) { continue }
      $winner = $winner[0]
      $matching = @($entries | Where-Object { [string]$_.identityHash -eq [string]$winner.identityHash -and [string]$_.value -eq [string]$winner.value -and [string](Get-UserAdaptationProperty $_ 'parameterHash' (Get-UserAdaptationHash '{}')) -eq [string]$winner.parameterHash } | Select-Object -First 1)
      $current = @($entries | Where-Object { [string]$_.identityHash -eq [string]$winner.identityHash -and [string]$_.status -eq 'active' })
      if ($matching.Count -gt 0) {
        $entry=$matching[0];foreach($previous in @($current|Where-Object{[string]$_.preferenceId-ne[string]$entry.preferenceId})){$previous.status='superseded';$previous|Add-Member -NotePropertyName supersededBy -NotePropertyValue ([string]$entry.preferenceId) -Force;$previous.updatedAt=$Now.ToString('o')};$entry.status='active';$entry.source=$winner.source;$entry|Add-Member -NotePropertyName baseConfidence -NotePropertyValue $winner.baseConfidence -Force;$entry.confidence=$winner.confidence;$entry.supportCount=$winner.supportCount;$entry.distinctTaskCount=$winner.distinctTaskCount;$entry.distinctContextCount=$winner.distinctContextCount;$entry.contradictionCount=$winner.contradictionCount;$entry.contexts=@($winner.contexts);$entry|Add-Member -NotePropertyName lastEvidenceAt -NotePropertyValue $winner.lastSeenAt -Force;$entry.updatedAt=$Now.ToString('o')
        $winner.preferenceId=[string]$entry.preferenceId
      } else {
        $canReplace = ($current.Count -eq 0) -or ([string]$winner.source -eq 'explicit_user') -or ([string]$current[0].source -ne 'explicit_user' -and [double]$winner.confidence -ge ([double]$current[0].confidence + [double]$policy.promotion.inferredReplacementMargin))
        if ($canReplace) {
          foreach($previous in @($current)){$previous.status='superseded';$previous|Add-Member -NotePropertyName supersededBy -NotePropertyValue $winner.preferenceId -Force;$previous.updatedAt=$Now.ToString('o')}
          $entries += [pscustomobject]@{preferenceId=$winner.preferenceId;identityHash=$winner.identityHash;identityGeneration=$winner.identityGeneration;scope=$winner.scope;scopeKey=$winner.scopeKey;habitKey=$winner.habitKey;value=$winner.value;valueKind=$winner.valueKind;parameters=$winner.parameters;parameterHash=$winner.parameterHash;source=$winner.source;baseConfidence=$winner.baseConfidence;confidence=$winner.confidence;supportCount=$winner.supportCount;distinctTaskCount=$winner.distinctTaskCount;distinctContextCount=$winner.distinctContextCount;contradictionCount=$winner.contradictionCount;contexts=@($winner.contexts);lastEvidenceAt=$winner.lastSeenAt;status='active';updatedAt=$Now.ToString('o');rawPromptStored=$false}
          [void]$promoted.Add([string]$winner.preferenceId)
        } else { $winner.status='conflicted' }
      }
    }

    foreach ($entry in @($entries | Where-Object { [string]$_.status -eq 'active' -and [string]$_.source -ne 'explicit_user' })) {
      $lastAt = [string](Get-UserAdaptationProperty $entry 'lastEvidenceAt' ([string]$entry.updatedAt))
      $baseConfidence = [double](Get-UserAdaptationProperty $entry 'baseConfidence' ([double]$entry.confidence))
      try {
        $lastDate = [datetime]$lastAt
        if ($lastDate -gt $Now.AddDays([int]$policy.promotion.maximumFutureEvidenceSkewDays)) { throw 'future' }
        $age = [Math]::Max(0.0,($Now - $lastDate).TotalDays)
      } catch { $age = [double]$policy.promotion.inferredGraceDays + [double]$policy.promotion.decayIntervalDays }
      $entry.confidence = $baseConfidence
      if ($age -gt [double]$policy.promotion.inferredGraceDays) {
        $steps = [Math]::Floor(($age-[double]$policy.promotion.inferredGraceDays)/[double]$policy.promotion.decayIntervalDays)+1
        $entry.confidence = [Math]::Round([Math]::Max(0.0,$baseConfidence-([double]$policy.promotion.decayPerInterval*$steps)),4)
        if ([double]$entry.confidence -lt [double]$policy.packet.minimumConfidence) { $entry.status='dormant';$entry|Add-Member -NotePropertyName dormantReason -NotePropertyValue 'confidence_decay' -Force;$entry.updatedAt=$Now.ToString('o');[void]$suppressed.Add([string]$entry.preferenceId) }
      }
    }
    $entries = @($entries | Sort-Object @{Expression={if($_.status-eq'active'){1}else{0}};Descending=$true}, @{Expression='updatedAt';Descending=$true} | Select-Object -First ([int]$policy.storage.maxStablePreferences))
    $profilePressure='ok'
    $profileProbe=[pscustomobject]@{entries=$entries}
    while(($profileProbe|ConvertTo-Json -Depth 20 -Compress).Length -gt [int]$policy.storage.maxProfileChars){$removable=@($entries|Where-Object{$_.status-ne'active'}|Sort-Object updatedAt|Select-Object -First 1);if($removable.Count-eq0){$profilePressure='active_preferences_exceed_budget';break};$entries=@($entries|Where-Object{$_.preferenceId-ne$removable[0].preferenceId});$profileProbe.entries=$entries}
    $fromRevision=[int]$store.revision
    $store.observations=@($observations);$store.candidates=@($candidates|Sort-Object lastSeenAt -Descending|Select-Object -First ([int]$policy.storage.maxCandidates));$store.profile=@($entries);$store.profilePressure=$profilePressure;$store.policyHash=Get-UserAdaptationPolicyHash $Root;$store.revision=$fromRevision+1;$store.updatedAt=$Now.ToString('o')
    $lifecycleChanges=Get-UserAdaptationLifecycleChanges $beforeCandidates $beforeProfile @($store.candidates) @($store.profile) 'synthesis'
    $receipt=Add-UserAdaptationReceipt $Root $store 'synthesis' $TransitionId $payloadHash $fromRevision ([int]$store.revision) '' @() $lifecycleChanges
    Write-UserAdaptationJson $paths.storeV2 $store 30 -Compact
    return [pscustomobject]@{ok=$true;action='Synthesize';replayed=$false;revision=[int]$store.revision;receiptId=$receipt.receiptId;observationCount=@($store.observations).Count;candidateCount=@($store.candidates).Count;validatedCandidateCount=@($store.candidates|Where-Object{$_.validation-and[string]$_.validation.status-eq'validated'}).Count;activePreferenceCount=@($store.profile|Where-Object{$_.status-eq'active'}).Count;stagedPreferenceCount=@($store.candidates|Where-Object{$_.status-eq'staged'}).Count;dormantPreferenceCount=@($store.profile|Where-Object{$_.status-eq'dormant'}).Count;promotedPreferenceIds=@($promoted);suppressedPreferenceIds=@($suppressed|Select-Object -Unique);profilePressure=$profilePressure;rawPromptStored=$false}
  } 10000 120
}

function Get-UserAdaptationPacketPriority($Entry) {
  switch ([string](Get-UserAdaptationProperty $Entry 'habitKey' '')) {
    'correction_learning' { return 100 }
    'collaboration_stance' { return 95 }
    'proactivity' { return 90 }
    'response_detail' { return 80 }
    'verification_depth' { return 70 }
    'feature_thinking' { return 65 }
    'reasoning_style' { return 60 }
    default { return 50 }
  }
}

function Get-UserAdaptationPacketV2 {
  param([string]$Root,[string]$Context='general',[string]$WorkspaceKey='',[string]$WorkflowKey='',[string]$WorkspaceRoot='')
  $policy=Get-UserAdaptationPolicy $Root
  $store=Get-UserAdaptationV2Store $Root $WorkspaceRoot
  if($store.enabled-ne$true){return [pscustomobject]@{ok=$true;action='Packet';schema='super-brain.user-adaptation-packet.v2';enabled=$false;applies=$false;context=$Context;directiveCount=0;tokenEstimate=0;charCount=0;directives=@();preferences=@();revision=[int]$store.revision;rawPromptStored=$false;guard=[string]$policy.authority}}
  if([string]$store.policyHash-ne(Get-UserAdaptationPolicyHash $Root)){return [pscustomobject]@{ok=$true;action='Packet';schema='super-brain.user-adaptation-packet.v2';enabled=$true;applies=$false;context=$Context;directiveCount=0;tokenEstimate=0;charCount=0;directives=@();preferences=@();revision=[int]$store.revision;rawPromptStored=$false;guard='Policy binding is stale; no personalization packet is authorized.'}}
  $workspaceKeyNormalized=([string]$WorkspaceKey).Trim().ToLowerInvariant();$workflowKeyNormalized=([string]$WorkflowKey).Trim().ToLowerInvariant();$scopedWorkflowKey=if([string]::IsNullOrWhiteSpace($workspaceKeyNormalized)-or[string]::IsNullOrWhiteSpace($workflowKeyNormalized)){''}else{"$workspaceKeyNormalized`:$workflowKeyNormalized"}
  $matching=@($store.profile|Where-Object{
    if([string]$_.status-ne'active'-or[double]$_.confidence-lt[double]$policy.packet.minimumConfidence){return $false}
    $identityState=Get-UserAdaptationIdentityGeneration $store ([string]$_.identityHash);if($identityState.blocked-or[int]$_.identityGeneration-ne[int]$identityState.current){return $false}
    if(@($store.legacyPreferenceHashes)-contains(Get-UserAdaptationHash ([string]$_.preferenceId))){return $false}
    $rule=Get-UserAdaptationHabitRule $policy ([string]$_.habitKey) ([string]$_.value);if(@($rule.contexts).Count-gt0-and@($rule.contexts)-notcontains$Context){return $false}
    $parameterContexts=@();if($_.parameters-and$_.parameters.PSObject.Properties['contexts']){$parameterContexts=@($_.parameters.contexts)}
    if([string](Get-UserAdaptationProperty $_ 'valueKind' 'enum')-eq'bounded_parameters'-and$parameterContexts.Count-gt0-and$parameterContexts-notcontains$Context){return $false}
    $scopeMatch=([string]$_.scope-eq'global')-or([string]$_.scope-eq'project'-and-not[string]::IsNullOrWhiteSpace($workspaceKeyNormalized)-and[string]$_.scopeKey-eq$workspaceKeyNormalized)-or([string]$_.scope-eq'workflow'-and-not[string]::IsNullOrWhiteSpace($workflowKeyNormalized)-and([string]$_.scopeKey-eq$scopedWorkflowKey))
    if(-not$scopeMatch){return $false};return([string]$_.source-eq'explicit_user'-or@($_.contexts)-contains$Context-or@($_.contexts)-contains'general')
  })
  $rank=@{global=1;project=2;workflow=3};$selected=New-Object Collections.ArrayList
  foreach($group in @($matching|Group-Object habitKey)){$winner=@($group.Group|Sort-Object @{Expression={[int]$rank[[string]$_.scope]};Descending=$true},@{Expression='confidence';Descending=$true},@{Expression='updatedAt';Descending=$true}|Select-Object -First 1);if($winner.Count-gt0){[void]$selected.Add($winner[0])}}
  $directives=New-Object Collections.ArrayList;$preferences=New-Object Collections.ArrayList;$chars=0
  foreach($entry in @($selected|Sort-Object @{Expression={Get-UserAdaptationPacketPriority $_};Descending=$true},@{Expression={[int]$rank[[string]$_.scope]};Descending=$true},@{Expression='confidence';Descending=$true},@{Expression='updatedAt';Descending=$true})){
    $directive=Get-UserAdaptationRenderedDirective $Root $policy $entry;$separator=if($directives.Count-gt0){1}else{0};$projected=$chars+$separator+$directive.Length
    if($directives.Count-ge[int]$policy.packet.maxDirectives-or$projected-gt[int]$policy.packet.maxChars-or[Math]::Ceiling($projected/4.0)-gt[int]$policy.packet.maxTokens){continue}
    [void]$directives.Add($directive);[void]$preferences.Add([pscustomobject]@{preferenceId=$entry.preferenceId;habitKey=$entry.habitKey;value=$entry.value;scope=$entry.scope;confidence=$entry.confidence});$chars=$projected
  }
  return [pscustomobject]@{ok=$true;action='Packet';schema='super-brain.user-adaptation-packet.v2';enabled=$true;applies=($directives.Count-gt0);context=$Context;directiveCount=$directives.Count;tokenEstimate=[int][Math]::Ceiling($chars/4.0);charCount=$chars;directives=@($directives);preferences=@($preferences);revision=[int]$store.revision;generation=[int]$store.generation;policyHash=[string]$store.policyHash;rawPromptStored=$false;guard=[string]$policy.authority}
}

function Set-UserAdaptationEnabledV2 {
  param([string]$Root,[bool]$Enabled,[string]$WorkspaceRoot='',[int]$ExpectedRevision=-1,[string]$TransitionId='')
  $paths=Get-UserAdaptationPaths $Root $WorkspaceRoot
  $kind=if($Enabled){'enable'}else{'disable'};$payloadHash=Get-UserAdaptationPayloadHash ([ordered]@{operation=$kind;enabled=$Enabled})
  return Invoke-SuperBrainFileLock $paths.coordination {
    $store=Get-UserAdaptationV2Store $Root $WorkspaceRoot;$replayed=Get-UserAdaptationReplay $store $kind $TransitionId $payloadHash;if($replayed){return [pscustomobject]@{ok=$true;action=if($Enabled){'Enable'}else{'Disable'};enabled=$Enabled;replayed=$true;revision=[int]$store.revision;receiptId=[string]$replayed.receiptId;rawPromptStored=$false}}
    if($ExpectedRevision-lt0){throw'USER_ADAPTATION_EXPECTED_REVISION_REQUIRED'};if([int]$store.revision-ne$ExpectedRevision){throw "USER_ADAPTATION_REVISION_MISMATCH expected=$ExpectedRevision actual=$([int]$store.revision)"}
    $from=[int]$store.revision;$store.enabled=$Enabled;$store.revision=$from+1;$store.updatedAt=(Get-Date).ToString('o');$receipt=Add-UserAdaptationReceipt $Root $store $kind $TransitionId $payloadHash $from ([int]$store.revision);Write-UserAdaptationJson $paths.storeV2 $store 30 -Compact
    return [pscustomobject]@{ok=$true;action=if($Enabled){'Enable'}else{'Disable'};enabled=$Enabled;replayed=$false;revision=[int]$store.revision;receiptId=$receipt.receiptId;rawPromptStored=$false}
  } 5000 120
}

function Remove-UserAdaptationPreferenceV2 {
  param([string]$Root,[string]$PreferenceId,[string]$WorkspaceRoot='',[int]$ExpectedRevision=-1,[string]$TransitionId='',[switch]$Confirmed)
  if([string]::IsNullOrWhiteSpace($PreferenceId)){throw'USER_ADAPTATION_PREFERENCE_ID_REQUIRED'}
  if(-not$Confirmed){throw'USER_ADAPTATION_FORGET_REQUIRES_CONFIRMATION'}
  $paths=Get-UserAdaptationPaths $Root $WorkspaceRoot
  $payloadHash=Get-UserAdaptationPayloadHash ([ordered]@{operation='forget';preferenceId=$PreferenceId})
  return Invoke-SuperBrainFileLock $paths.coordination {
    $store=Get-UserAdaptationV2Store $Root $WorkspaceRoot;$replayed=Get-UserAdaptationReplay $store 'forget' $TransitionId $payloadHash;if($replayed){return [pscustomobject]@{ok=$true;action='Forget';found=$true;replayed=$true;preferenceId=$PreferenceId;revision=[int]$store.revision;receiptId=[string]$replayed.receiptId;rawPromptStored=$false}}
    if($ExpectedRevision-lt0){throw'USER_ADAPTATION_EXPECTED_REVISION_REQUIRED'};if([int]$store.revision-ne$ExpectedRevision){throw "USER_ADAPTATION_REVISION_MISMATCH expected=$ExpectedRevision actual=$([int]$store.revision)"}
    $target=@($store.profile|Where-Object{[string]$_.preferenceId-eq$PreferenceId}|Select-Object -First 1);if($target.Count-eq0){return [pscustomobject]@{ok=$true;action='Forget';found=$false;replayed=$false;preferenceId=$PreferenceId;revision=[int]$store.revision;rawPromptStored=$false}}
    $target=$target[0];$identityHash=[string]$target.identityHash;$generation=[int](Get-UserAdaptationProperty $target 'identityGeneration' 1);$existing=@($store.tombstones|Where-Object{[string]$_.identityHash-eq$identityHash}|Select-Object -First 1);$now=(Get-Date).ToString('o')
    if($existing.Count-gt0){$t=$existing[0];$t.forgottenThroughGeneration=[Math]::Max([int](Get-UserAdaptationProperty $t 'forgottenThroughGeneration' 0),$generation);$t.currentGeneration=$generation;$t.forgottenAt=$now;$t.reinstatedAt=''}else{$store.tombstones=@($store.tombstones)+@([pscustomobject]@{identityHash=$identityHash;forgottenThroughGeneration=$generation;currentGeneration=$generation;forgottenAt=$now;reinstatedAt='';rawPromptStored=$false})}
    $forgetChanges=@([pscustomobject]@{entityType='preference';entityId=[string]$target.preferenceId;fromStatus=[string]$target.status;toStatus='forgotten';reasonCode='forget';scope=[string]$target.scope})
    $store.profile=@($store.profile|Where-Object{[string]$_.identityHash-ne$identityHash});$store.candidates=@($store.candidates|Where-Object{[string]$_.identityHash-ne$identityHash});$store.observations=@($store.observations|Where-Object{[string]$_.identityHash-ne$identityHash})
    $from=[int]$store.revision;$store.generation=[int]$store.generation+1;$store.revision=$from+1;$store.updatedAt=$now;$store.receipts=@($store.receipts|Where-Object{[string]$_.identityHash-ne$identityHash-and@($_.identityHashes)-notcontains$identityHash});$receipt=Add-UserAdaptationReceipt $Root $store 'forget' $TransitionId $payloadHash $from ([int]$store.revision) $identityHash @() $forgetChanges;Write-UserAdaptationJson $paths.storeV2 $store 30 -Compact
    return [pscustomobject]@{ok=$true;action='Forget';found=$true;replayed=$false;preferenceId=$PreferenceId;identityGeneration=$generation;revision=[int]$store.revision;receiptId=$receipt.receiptId;rawPromptStored=$false}
  } 5000 120
}

function Invoke-UserAdaptationReinstateV2 {
  param([string]$Root,[string]$Scope,[string]$ScopeKey,[string]$HabitKey,[string]$WorkspaceRoot='',[int]$ExpectedRevision=-1,[string]$TransitionId='',[switch]$Confirmed)
  if(-not$Confirmed){throw'USER_ADAPTATION_REINSTATE_REQUIRES_CONFIRMATION'}
  $paths=Get-UserAdaptationPaths $Root $WorkspaceRoot;$identity=Get-UserAdaptationIdentity $Scope $ScopeKey $HabitKey
  $payloadHash=Get-UserAdaptationPayloadHash ([ordered]@{operation='reinstate';scope=$Scope;scopeKey=(Resolve-UserAdaptationScopeKey $Scope $ScopeKey);habitKey=$HabitKey})
  return Invoke-SuperBrainFileLock $paths.coordination {
    $store=Get-UserAdaptationV2Store $Root $WorkspaceRoot;$replayed=Get-UserAdaptationReplay $store 'reinstate' $TransitionId $payloadHash;if($replayed){$state=Get-UserAdaptationIdentityGeneration $store $identity.hash;return [pscustomobject]@{ok=$true;action='Reinstate';replayed=$true;identityGeneration=[int]$state.current;revision=[int]$store.revision;receiptId=[string]$replayed.receiptId;rawPromptStored=$false}}
    if($ExpectedRevision-lt0){throw'USER_ADAPTATION_EXPECTED_REVISION_REQUIRED'};if([int]$store.revision-ne$ExpectedRevision){throw "USER_ADAPTATION_REVISION_MISMATCH expected=$ExpectedRevision actual=$([int]$store.revision)"}
    $tombstone=@($store.tombstones|Where-Object{[string]$_.identityHash-eq$identity.hash}|Select-Object -First 1);if($tombstone.Count-eq0){throw'USER_ADAPTATION_TOMBSTONE_NOT_FOUND'};$t=$tombstone[0];$state=Get-UserAdaptationIdentityGeneration $store $identity.hash;if(-not$state.blocked){throw'USER_ADAPTATION_REINSTATE_NOT_BLOCKED'};$next=[int]$t.forgottenThroughGeneration+1;$t.currentGeneration=$next;$t.reinstatedAt=(Get-Date).ToString('o')
    $identityEventId='identity-'+([string]$identity.hash).Substring(0,16)
    $reinstateChanges=@([pscustomobject]@{entityType='identity';entityId=$identityEventId;fromStatus='forgotten';toStatus='reinstated';reasonCode='reinstate';scope=$Scope})
    $from=[int]$store.revision;$store.generation=[int]$store.generation+1;$store.revision=$from+1;$store.updatedAt=(Get-Date).ToString('o');$receipt=Add-UserAdaptationReceipt $Root $store 'reinstate' $TransitionId $payloadHash $from ([int]$store.revision) $identity.hash @() $reinstateChanges;Write-UserAdaptationJson $paths.storeV2 $store 30 -Compact
    return [pscustomobject]@{ok=$true;action='Reinstate';replayed=$false;identityGeneration=$next;revision=[int]$store.revision;receiptId=$receipt.receiptId;rawPromptStored=$false}
  } 5000 120
}

function Get-UserAdaptationStatusV2([string]$Root,[string]$WorkspaceRoot='') {
  $policy=Get-UserAdaptationPolicy $Root;$paths=Get-UserAdaptationPaths $Root $WorkspaceRoot;$store=Get-UserAdaptationV2Store $Root $WorkspaceRoot
  return [pscustomobject]@{ok=$true;action='Status';schema='super-brain.user-adaptation-status.v2';trustLevel='local_same_user_unattested';enabled=[bool]$store.enabled;revision=[int]$store.revision;generation=[int]$store.generation;observationCount=@($store.observations).Count;candidateCount=@($store.candidates).Count;validatedCandidateCount=@($store.candidates|Where-Object{$_.validation-and[string]$_.validation.status-eq'validated'}).Count;activePreferenceCount=@($store.profile|Where-Object{$_.status-eq'active'}).Count;stagedPreferenceCount=@($store.candidates|Where-Object{$_.status-eq'staged'}).Count;dormantPreferenceCount=@($store.profile|Where-Object{$_.status-eq'dormant'}).Count;tombstoneCount=@($store.tombstones).Count;legacyTombstoneCount=@($store.legacyPreferenceHashes).Count;receiptCount=@($store.receipts).Count;profileChars=($store.profile|ConvertTo-Json -Depth 20 -Compress).Length;profilePressure=[string]$store.profilePressure;policyCurrent=([string]$store.policyHash-eq(Get-UserAdaptationPolicyHash $Root));budgets=[pscustomobject]@{maxObservations=[int]$policy.storage.maxObservations;maxCandidates=[int]$policy.storage.maxCandidates;maxStablePreferences=[int]$policy.storage.maxStablePreferences;maxProfileChars=[int]$policy.storage.maxProfileChars;maxDirectives=[int]$policy.packet.maxDirectives;maxTokens=[int]$policy.packet.maxTokens;maxChars=[int]$policy.packet.maxChars};rawPromptStored=$false;directory=$paths.directory}
}

function Get-UserAdaptationEvolutionHistory($Store) {
  $receipts = @($Store.receipts | Sort-Object @{Expression={[int](Get-UserAdaptationProperty $_ 'toRevision' 0)};Ascending=$true}, @{Expression={[string](Get-UserAdaptationProperty $_ 'recordedAt' '')};Ascending=$true})
  $events = @()
  $chainComplete = ($receipts.Count -gt 0)
  $previousChainHash = ''
  for ($index = 0; $index -lt $receipts.Count; $index++) {
    $receipt = $receipts[$index]
    $chainHash = [string](Get-UserAdaptationProperty $receipt 'chainHash' '')
    $declaredPrevious = [string](Get-UserAdaptationProperty $receipt 'previousChainHash' '')
    if ($chainHash -notmatch '^[a-f0-9]{64}$') { $chainComplete = $false }
    if ($index -eq 0) {
      if (-not [string]::IsNullOrWhiteSpace($declaredPrevious)) { $chainComplete = $false }
    } elseif ($declaredPrevious -ne $previousChainHash) { $chainComplete = $false }
    $changes = @()
    if ($receipt.PSObject.Properties['lifecycleChanges']) {
      try { $changes = ConvertTo-UserAdaptationLifecycleChanges @($receipt.lifecycleChanges) 8 } catch { $chainComplete = $false; $changes = @() }
    }
    foreach ($change in @($changes)) {
      $events += [pscustomobject]@{receiptId=[string](Get-UserAdaptationProperty $receipt 'receiptId' '');recordedAt=[string](Get-UserAdaptationProperty $receipt 'recordedAt' '');revision=[int](Get-UserAdaptationProperty $receipt 'toRevision' 0);entityType=[string]$change.entityType;entityId=[string]$change.entityId;fromStatus=[string]$change.fromStatus;toStatus=[string]$change.toStatus;reasonCode=[string]$change.reasonCode;scope=[string]$change.scope}
    }
    $previousChainHash = $chainHash
  }
  $coverage = if (@($Store.tombstones).Count -gt 0) { 'redacted' } elseif ($receipts.Count -eq 0) { 'unavailable' } elseif ($chainComplete) { 'complete' } else { 'partial' }
  $firstRetainedRevision = if ($receipts.Count) { [int](Get-UserAdaptationProperty $receipts[0] 'fromRevision' 0) } else { 0 }
  $windowStart = if ($receipts.Count) { [string](Get-UserAdaptationProperty $receipts[0] 'recordedAt' '') } else { '' }
  $windowEnd = if ($receipts.Count) { [string](Get-UserAdaptationProperty $receipts[-1] 'recordedAt' '') } else { '' }
  $retainedEvents = @($events | Sort-Object @{Expression='recordedAt';Descending=$true}, @{Expression='revision';Descending=$true} | Select-Object -First 12)
  return [pscustomobject]@{coverage=$coverage;historyComplete=($coverage -eq 'complete');firstRetainedRevision=$firstRetainedRevision;windowStart=$windowStart;windowEnd=$windowEnd;receiptCount=$receipts.Count;retainedEvents=$retainedEvents;allEvents=@($events)}
}

function New-UserAdaptationNotScoredMetric([string]$ReasonCode) {
  return [pscustomobject]@{status='not_scored';reasonCode=$ReasonCode;numerator=0;denominator=0;rawPromptStored=$false}
}

function Get-UserAdaptationEvolutionV2([string]$Root,[string]$WorkspaceRoot='') {
  $policy = Get-UserAdaptationPolicy $Root
  $store = Get-UserAdaptationV2Store $Root $WorkspaceRoot
  $history = Get-UserAdaptationEvolutionHistory $store
  $metricReason = if ($history.coverage -eq 'redacted') { 'history_redacted' } elseif ($history.coverage -ne 'complete') { 'retained_history_incomplete' } else { 'paired_comparison_manifest_required' }
  $events = @($history.allEvents)
  $counts = [pscustomobject]@{
    retainedLifecycleEvents=$events.Count
    candidateCreated=@($events | Where-Object { $_.entityType -eq 'candidate' -and [string]::IsNullOrWhiteSpace([string]$_.fromStatus) }).Count
    preferenceActivated=@($events | Where-Object { $_.entityType -eq 'preference' -and $_.toStatus -eq 'active' -and $_.fromStatus -ne 'active' }).Count
    preferenceDormant=@($events | Where-Object { $_.entityType -eq 'preference' -and $_.toStatus -eq 'dormant' }).Count
    validatedCandidates=@($store.candidates | Where-Object { $_.validation -and [string]$_.validation.status -eq 'validated' }).Count
    corrections=@($events | Where-Object { $_.reasonCode -eq 'verified_correction' }).Count
    forgotten=@($events | Where-Object { $_.reasonCode -eq 'forget' }).Count
    reinstated=@($events | Where-Object { $_.entityType -eq 'identity' -and $_.reasonCode -eq 'reinstate' -and $_.toStatus -eq 'reinstated' }).Count
  }
  return [pscustomobject]@{
    ok=$true;action='Evolution';schema='super-brain.user-adaptation-evolution.v1';trustLevel='local_same_user_unattested';claimBoundary='local_hash_checked_retained_history_not_human_attested';revision=[int]$store.revision;generation=[int]$store.generation
    history=[pscustomobject]@{retention='bounded_local';coverage=[string]$history.coverage;historyComplete=[bool]$history.historyComplete;firstRetainedRevision=[int]$history.firstRetainedRevision;windowStart=[string]$history.windowStart;windowEnd=[string]$history.windowEnd;receiptCount=[int]$history.receiptCount}
    currentState=[pscustomobject]@{observations=@($store.observations).Count;candidates=@($store.candidates).Count;validatedCandidates=@($store.candidates|Where-Object{$_.validation-and[string]$_.validation.status-eq'validated'}).Count;activePreferences=@($store.profile|Where-Object{$_.status-eq'active'}).Count;stagedCandidates=@($store.candidates|Where-Object{$_.status-eq'staged'}).Count;dormantPreferences=@($store.profile|Where-Object{$_.status-eq'dormant'}).Count;tombstones=@($store.tombstones).Count}
    retainedChangeCounts=$counts;recentChanges=@($history.retainedEvents)
    metrics=[pscustomobject]@{schema='super-brain.user-adaptation-metric-contract.v1';activationVelocity=New-UserAdaptationNotScoredMetric $metricReason;correctionLatency=New-UserAdaptationNotScoredMetric $metricReason;promotionPrecision=New-UserAdaptationNotScoredMetric $metricReason;reversalRate=New-UserAdaptationNotScoredMetric $metricReason}
    evaluation=[pscustomobject]@{status='not_scored';reasonCode='paired_comparison_manifest_required';improvementClaimAllowed=$false;rawPromptStored=$false}
    localLifecycleChangeObserved=($events.Count -gt 0);rawPromptStored=$false
  }
}

function Get-UserAdaptationExplainV2([string]$Root,[string]$PreferenceId='',[string]$CandidateId='',[string]$WorkspaceRoot='') {
  if (([string]::IsNullOrWhiteSpace($PreferenceId) -and [string]::IsNullOrWhiteSpace($CandidateId)) -or (-not [string]::IsNullOrWhiteSpace($PreferenceId) -and -not [string]::IsNullOrWhiteSpace($CandidateId))) {
    return [pscustomobject]@{ok=$false;action='Explain';code='USER_ADAPTATION_EXPLAIN_TARGET_REQUIRED';rawPromptStored=$false}
  }
  $store = Get-UserAdaptationV2Store $Root $WorkspaceRoot
  $entityType = if ([string]::IsNullOrWhiteSpace($PreferenceId)) { 'candidate' } else { 'preference' }
  $entityId = if ($entityType -eq 'candidate') { $CandidateId.Trim().ToLowerInvariant() } else { $PreferenceId.Trim().ToLowerInvariant() }
  $target = if ($entityType -eq 'candidate') { @($store.candidates | Where-Object { [string]$_.candidateId -eq $entityId } | Select-Object -First 1) } else { @($store.profile | Where-Object { [string]$_.preferenceId -eq $entityId } | Select-Object -First 1) }
  if (@($target).Count -ne 1) { return [pscustomobject]@{ok=$false;action='Explain';code='USER_ADAPTATION_EXPLAIN_TARGET_NOT_FOUND';entityType=$entityType;entityId=$entityId;trustLevel='local_same_user_unattested';rawPromptStored=$false} }
  $entry = @($target)[0]
  $history = Get-UserAdaptationEvolutionHistory $store
  $events = @($history.allEvents | Where-Object { $_.entityType -eq $entityType -and $_.entityId -eq $entityId } | Sort-Object recordedAt -Descending | Select-Object -First 8)
  return [pscustomobject]@{
    ok=$true;action='Explain';schema='super-brain.user-adaptation-explain.v1';trustLevel='local_same_user_unattested';claimBoundary='local_hash_checked_retained_history_not_human_attested';entity=[pscustomobject]@{entityType=$entityType;entityId=$entityId;habitKey=[string](Get-UserAdaptationProperty $entry 'habitKey' '');value=[string](Get-UserAdaptationProperty $entry 'value' '');valueKind=[string](Get-UserAdaptationProperty $entry 'valueKind' '');scope=[string](Get-UserAdaptationProperty $entry 'scope' '');status=[string](Get-UserAdaptationProperty $entry 'status' '');source=[string](Get-UserAdaptationProperty $entry 'source' '');confidence=[double](Get-UserAdaptationProperty $entry 'confidence' 0);supportCount=[int](Get-UserAdaptationProperty $entry 'supportCount' 0);distinctTaskCount=[int](Get-UserAdaptationProperty $entry 'distinctTaskCount' 0);distinctContextCount=[int](Get-UserAdaptationProperty $entry 'distinctContextCount' 0);contradictionCount=[int](Get-UserAdaptationProperty $entry 'contradictionCount' 0);lastEvidenceAt=[string](Get-UserAdaptationProperty $entry 'lastEvidenceAt' (Get-UserAdaptationProperty $entry 'lastSeenAt' ''));validation=if($entry.validation){[pscustomobject]@{status=[string](Get-UserAdaptationProperty $entry.validation 'status' 'pending');scopedEvidence=([bool](Get-UserAdaptationProperty $entry.validation 'scopedEvidence' $false));overfitGuardPassed=([bool](Get-UserAdaptationProperty $entry.validation 'overfitGuardPassed' $false));validatedAt=[string](Get-UserAdaptationProperty $entry.validation 'validatedAt' '');rawPromptStored=$false}}else{[pscustomobject]@{status='not_recorded';scopedEvidence=$false;overfitGuardPassed=$false;validatedAt='';rawPromptStored=$false}}};history=[pscustomobject]@{coverage=[string]$history.coverage;historyComplete=[bool]$history.historyComplete;retainedEvents=@($events)};evaluation=[pscustomobject]@{status='not_scored';reasonCode='paired_comparison_manifest_required';improvementClaimAllowed=$false};rawPromptStored=$false
  }
}

function Get-UserAdaptationState([string]$Root, [string]$WorkspaceRoot = '') {
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  $policy = Get-UserAdaptationPolicy $Root
  if (Test-Path -LiteralPath $paths.storeV2 -PathType Leaf) {
    $store = Get-UserAdaptationV2Store $Root $WorkspaceRoot
    return [pscustomobject]@{schema='super-brain.user-adaptation-state.v2';enabled=[bool]$store.enabled;revision=[int]$store.revision;generation=[int]$store.generation;updatedAt=[string]$store.updatedAt;rawPromptStored=$false}
  }
  return Read-UserAdaptationJson $paths.state ([pscustomobject]@{ schema='super-brain.user-adaptation-state.v1'; enabled=[bool]$policy.enabled; updatedAt=''; rawPromptStored=$false })
}

function Resolve-UserAdaptationScopeKey([string]$Scope, [string]$ScopeKey) {
  if ($Scope -notin @('global','project','workflow')) { throw 'USER_ADAPTATION_SCOPE_INVALID' }
  if ($Scope -eq 'global') { return 'global' }
  $value = ([string]$ScopeKey).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($value)) { throw 'USER_ADAPTATION_SCOPE_KEY_REQUIRED' }
  if ($value -notmatch '^[a-z0-9._:-]{1,80}$') { throw 'USER_ADAPTATION_SCOPE_KEY_INVALID' }
  return $value
}

function Get-UserAdaptationHabitRule($Policy, [string]$HabitKey, [string]$Value) {
  $habitProperty = $Policy.habits.PSObject.Properties[$HabitKey]
  if (-not $habitProperty) { throw 'USER_ADAPTATION_HABIT_KEY_INVALID' }
  $valueProperty = $habitProperty.Value.values.PSObject.Properties[$Value]
  if (-not $valueProperty) { throw 'USER_ADAPTATION_VALUE_INVALID' }
  $rawValue = $valueProperty.Value
  $directive = if ($rawValue -is [string]) { [string]$rawValue } else { [string]$rawValue.directive }
  if ([string]::IsNullOrWhiteSpace($directive)) { throw 'USER_ADAPTATION_DIRECTIVE_INVALID' }
  $contexts = if ($rawValue -is [string]) { @() } else { @($rawValue.contexts) }
  return [pscustomobject]@{ habitKey=[string]$habitProperty.Name; value=[string]$valueProperty.Name; directive=$directive; contexts=$contexts }
}

function New-UserAdaptationStoreDefaults {
  return [pscustomobject]@{
    observations = [pscustomobject]@{ schema='super-brain.user-adaptation-observations.v1'; updatedAt=''; items=@(); rawPromptStored=$false }
    candidates = [pscustomobject]@{ schema='super-brain.user-adaptation-candidates.v1'; updatedAt=''; items=@(); rawPromptStored=$false }
    profile = [pscustomobject]@{ schema='super-brain.user-adaptation-profile.v1'; updatedAt=''; entries=@(); profilePressure='ok'; rawPromptStored=$false }
    tombstones = [pscustomobject]@{ schema='super-brain.user-adaptation-tombstones.v1'; updatedAt=''; items=@(); rawPromptStored=$false }
  }
}

function Add-UserAdaptationObservation {
  param(
    [string]$Root,
    [string]$HabitKey,
    [string]$Value,
    [ValidateSet('Support','Contradict')][string]$Signal = 'Support',
    [ValidateSet('explicit_user','repeated_behavior','accepted_outcome','user_correction')][string]$Source = 'repeated_behavior',
    [ValidateSet('global','project','workflow')][string]$Scope = 'global',
    [string]$ScopeKey = '',
    [ValidateSet('general','coding','debugging','planning','review','design','release')][string]$Context = 'general',
    [string]$TaskId = '',
    [string]$EvidenceRef = '',
    [string]$WorkspaceRoot = '',
    $Parameters = $null,
    [string]$EvidenceKind = 'auto',
    [string]$Producer = 'auto',
    [string]$EvidenceDate = '',
    [int]$ExpectedRevision = -1,
    [string]$TransitionId = '',
    [string]$CorrectionCandidateId = '',
    [string]$CorrectionCandidateHash = '',
    [string]$VerificationArtifactPath = '',
    [string]$VerificationHash = '',
    [string]$CorrectionTargetPreferenceId = ''
  )
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  if (Test-Path -LiteralPath $paths.storeV2 -PathType Leaf) {
    return Add-UserAdaptationObservationV2 -Root $Root -HabitKey $HabitKey -Value $Value -Signal $Signal -Source $Source -Scope $Scope -ScopeKey $ScopeKey -Context $Context -TaskId $TaskId -EvidenceRef $EvidenceRef -WorkspaceRoot $WorkspaceRoot -Parameters $Parameters -EvidenceKind $EvidenceKind -Producer $Producer -EvidenceDate $EvidenceDate -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId -CorrectionCandidateId $CorrectionCandidateId -CorrectionCandidateHash $CorrectionCandidateHash -VerificationArtifactPath $VerificationArtifactPath -VerificationHash $VerificationHash -CorrectionTargetPreferenceId $CorrectionTargetPreferenceId
  }
  # V1 remains readable for status and migration, but cannot accept new evidence.
  throw 'USER_ADAPTATION_V2_MIGRATION_REQUIRED'
  $policy = Get-UserAdaptationPolicy $Root
  $rule = Get-UserAdaptationHabitRule $policy $HabitKey $Value
  $resolvedScopeKey = Resolve-UserAdaptationScopeKey $Scope $ScopeKey
  if (@($policy.contexts) -notcontains $Context) { throw 'USER_ADAPTATION_CONTEXT_INVALID' }
  $safeTaskId = (([string]$TaskId -replace '[^A-Za-z0-9._-]+','-').Trim('-'))
  if ($safeTaskId.Length -gt 120) { $safeTaskId = $safeTaskId.Substring(0,120) }
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  New-Item -ItemType Directory -Force -Path $paths.directory | Out-Null
  $now = (Get-Date).ToString('o')
  $evidenceHash = Get-UserAdaptationHash $(if([string]::IsNullOrWhiteSpace($EvidenceRef)){"$Scope|$resolvedScopeKey|$HabitKey|$Value|$Signal|$safeTaskId|$Context"}else{$EvidenceRef})
  $observation = [pscustomobject]@{
    observationId = 'obs-' + (Get-UserAdaptationHash "$now|$evidenceHash|$([guid]::NewGuid().ToString('n'))" 8)
    habitKey = $rule.habitKey
    value = $rule.value
    signal = $Signal.ToLowerInvariant()
    source = $Source
    scope = $Scope
    scopeKey = $resolvedScopeKey
    context = $Context
    taskId = $safeTaskId
    evidenceHash = $evidenceHash
    recordedAt = $now
    rawPromptStored = $false
  }
  $result = Invoke-SuperBrainFileLock $paths.coordination {
    $defaults = New-UserAdaptationStoreDefaults
    $store = Read-UserAdaptationJson $paths.observations $defaults.observations
    $items = @($store.items)
    $duplicate = @($items | Where-Object { $_.evidenceHash -eq $observation.evidenceHash -and $_.habitKey -eq $HabitKey -and $_.value -eq $Value -and $_.signal -eq $observation.signal -and $_.scope -eq $Scope -and $_.scopeKey -eq $resolvedScopeKey }).Count -gt 0
    if (-not $duplicate) { $items += $observation }
    $items = @($items | Sort-Object recordedAt | Select-Object -Last ([int]$policy.storage.maxObservations))
    $updated = [pscustomobject]@{ schema='super-brain.user-adaptation-observations.v1'; updatedAt=$now; items=$items; rawPromptStored=$false }
    Write-UserAdaptationJson $paths.observations $updated 12
    return [pscustomobject]@{ ok=$true; action='Observe'; duplicate=$duplicate; observationId=if($duplicate){''}else{$observation.observationId}; observationCount=$items.Count; habitKey=$HabitKey; value=$Value; scope=$Scope; scopeKey=$resolvedScopeKey; rawPromptStored=$false }
  } 5000 120
  return $result
}

function Invoke-UserAdaptationSynthesis {
  param([string]$Root,[string]$WorkspaceRoot='',[int]$ExpectedRevision=-1,[string]$TransitionId='',[datetime]$Now=(Get-Date))
  $activePaths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  if (Test-Path -LiteralPath $activePaths.storeV2 -PathType Leaf) { return Invoke-UserAdaptationSynthesisV2 -Root $Root -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId -Now $Now }
  throw 'USER_ADAPTATION_V2_MIGRATION_REQUIRED'
  $policy = Get-UserAdaptationPolicy $Root
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  New-Item -ItemType Directory -Force -Path $paths.directory | Out-Null
  $result = Invoke-SuperBrainFileLock $paths.coordination {
    $defaults = New-UserAdaptationStoreDefaults
    $observationStore = Read-UserAdaptationJson $paths.observations $defaults.observations
    $candidateStore = Read-UserAdaptationJson $paths.candidates $defaults.candidates
    $profile = Read-UserAdaptationJson $paths.profile $defaults.profile
    $tombstones = Read-UserAdaptationJson $paths.tombstones $defaults.tombstones
    $cutoff = (Get-Date).AddDays(-[int]$policy.storage.observationRetentionDays)
    $observations = @($observationStore.items | Where-Object { try { [datetime]$_.recordedAt -ge $cutoff } catch { $false } } | Sort-Object recordedAt | Select-Object -Last ([int]$policy.storage.maxObservations))
    $supportGroups = @($observations | Where-Object { $_.signal -eq 'support' } | Group-Object { "$($_.scope)|$($_.scopeKey)|$($_.habitKey)|$($_.value)" })
    $candidates = New-Object Collections.ArrayList
    foreach ($group in $supportGroups) {
      $support = @($group.Group)
      $first = $support[0]
      $sameIdentity = @($observations | Where-Object { $_.scope -eq $first.scope -and $_.scopeKey -eq $first.scopeKey -and $_.habitKey -eq $first.habitKey })
      $directContradictions = @($sameIdentity | Where-Object { $_.value -eq $first.value -and $_.signal -eq 'contradict' }).Count
      $competingSupport = @($sameIdentity | Where-Object { $_.value -ne $first.value -and $_.signal -eq 'support' }).Count
      $contradictions = $directContradictions + $competingSupport
      $taskIds = @($support.taskId | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
      $contexts = @($support.context | Select-Object -Unique)
      $explicit = @($support | Where-Object { $_.source -eq 'explicit_user' }).Count -gt 0
      $confidence = if ($explicit) { [double]$policy.promotion.explicitUserConfidence } else {
        [double]$policy.promotion.inferredBaseConfidence + ([double]$policy.promotion.distinctTaskIncrement * $taskIds.Count) + ([double]$policy.promotion.distinctContextIncrement * $contexts.Count) - ([double]$policy.promotion.contradictionPenalty * $contradictions)
      }
      $confidence = [Math]::Round([Math]::Max([double]0.0,[Math]::Min([double]$confidence,[double]0.99)),4)
      $eligible = $explicit -or ($support.Count -ge [int]$policy.promotion.minimumSupport -and $taskIds.Count -ge [int]$policy.promotion.minimumDistinctTasks -and $contexts.Count -ge [int]$policy.promotion.minimumDistinctContexts -and $contradictions -le [int]$policy.promotion.maximumContradictions -and $confidence -ge [double]$policy.promotion.minimumConfidence)
      $identity = "$($first.scope)|$($first.scopeKey)|$($first.habitKey)|$($first.value)"
      $candidate = [pscustomobject]@{
        candidateId = 'candidate-' + (Get-UserAdaptationHash $identity 8)
        preferenceId = 'pref-' + (Get-UserAdaptationHash $identity 8)
        scope = [string]$first.scope
        scopeKey = [string]$first.scopeKey
        habitKey = [string]$first.habitKey
        value = [string]$first.value
        source = if($explicit){'explicit_user'}else{'inferred'}
        confidence = $confidence
        supportCount = $support.Count
        distinctTaskCount = $taskIds.Count
        distinctContextCount = $contexts.Count
        contradictionCount = $contradictions
        contexts = $contexts
        lastSeenAt = [string](@($support | Sort-Object recordedAt -Descending | Select-Object -First 1).recordedAt)
        status = if($eligible){'eligible'}else{'pending'}
        rawPromptStored = $false
      }
      $tombstoneHash = Get-UserAdaptationHash $candidate.preferenceId
      if (@($tombstones.items | Where-Object { $_.preferenceHash -eq $tombstoneHash }).Count -gt 0) { $candidate.status = 'forgotten' }
      [void]$candidates.Add($candidate)
    }

    $entries = @($profile.entries)
    $promoted = New-Object Collections.ArrayList
    foreach ($identityGroup in @($candidates | Where-Object { $_.status -eq 'eligible' } | Group-Object { "$($_.scope)|$($_.scopeKey)|$($_.habitKey)" })) {
      $winner = @($identityGroup.Group | Sort-Object @{Expression={if($_.source-eq'explicit_user'){1}else{0}};Descending=$true}, @{Expression='confidence';Descending=$true}, @{Expression='supportCount';Descending=$true}, @{Expression='lastSeenAt';Descending=$true} | Select-Object -First 1)[0]
      foreach ($loser in @($identityGroup.Group | Where-Object { $_.candidateId -ne $winner.candidateId })) { $loser.status = 'conflicted' }
      $active = $entries | Where-Object { $_.status -eq 'active' -and $_.scope -eq $winner.scope -and $_.scopeKey -eq $winner.scopeKey -and $_.habitKey -eq $winner.habitKey } | Select-Object -First 1
      if ($active -and $active.value -eq $winner.value) {
        $active.confidence = $winner.confidence
        $active.supportCount = $winner.supportCount
        $active.distinctTaskCount = $winner.distinctTaskCount
        $active.distinctContextCount = $winner.distinctContextCount
        $active.contradictionCount = $winner.contradictionCount
        $active.contexts = @($winner.contexts)
        $active.updatedAt = (Get-Date).ToString('o')
        $winner.status = 'promoted'
        continue
      }
      $canReplace = $true
      if ($active) {
        if ($active.source -eq 'explicit_user' -and $winner.source -ne 'explicit_user') { $canReplace = $false }
        elseif ($winner.source -ne 'explicit_user' -and [double]$winner.confidence -lt ([double]$active.confidence + [double]$policy.promotion.inferredReplacementMargin)) { $canReplace = $false }
      }
      if (-not $canReplace) { $winner.status = 'blocked_by_stronger_preference'; continue }
      if ($active) {
        $active.status = 'superseded'
        $active.supersededBy = $winner.preferenceId
        $active.updatedAt = (Get-Date).ToString('o')
      }
      $entry = [pscustomobject]@{
        preferenceId = $winner.preferenceId
        scope = $winner.scope
        scopeKey = $winner.scopeKey
        habitKey = $winner.habitKey
        value = $winner.value
        source = $winner.source
        confidence = $winner.confidence
        supportCount = $winner.supportCount
        distinctTaskCount = $winner.distinctTaskCount
        distinctContextCount = $winner.distinctContextCount
        contradictionCount = $winner.contradictionCount
        contexts = @($winner.contexts)
        status = 'active'
        updatedAt = (Get-Date).ToString('o')
        rawPromptStored = $false
      }
      $entries += $entry
      $winner.status = 'promoted'
      [void]$promoted.Add($entry.preferenceId)
    }

    $entries = @($entries | Sort-Object @{Expression={if($_.status-eq'active'){1}else{0}};Descending=$true}, @{Expression='updatedAt';Descending=$true} | Select-Object -First ([int]$policy.storage.maxStablePreferences))
    $profilePressure = 'ok'
    $profileObject = [pscustomobject]@{ schema='super-brain.user-adaptation-profile.v1'; updatedAt=(Get-Date).ToString('o'); entries=$entries; profilePressure='ok'; rawPromptStored=$false }
    while (($profileObject | ConvertTo-Json -Depth 12 -Compress).Length -gt [int]$policy.storage.maxProfileChars) {
      $removable = @($entries | Where-Object { $_.status -ne 'active' } | Sort-Object updatedAt | Select-Object -First 1)
      if (-not $removable) { $removable = @($entries | Where-Object { $_.source -ne 'explicit_user' } | Sort-Object confidence,updatedAt | Select-Object -First 1) }
      if (-not $removable) { $profilePressure = 'explicit_preferences_exceed_budget'; break }
      $entries = @($entries | Where-Object { $_.preferenceId -ne $removable.preferenceId })
      $profileObject.entries = $entries
    }
    $profileObject.profilePressure = $profilePressure
    $now = (Get-Date).ToString('o')
    Write-UserAdaptationJson $paths.observations ([pscustomobject]@{ schema='super-brain.user-adaptation-observations.v1'; updatedAt=$now; items=$observations; rawPromptStored=$false }) 12
    Write-UserAdaptationJson $paths.candidates ([pscustomobject]@{ schema='super-brain.user-adaptation-candidates.v1'; updatedAt=$now; items=@($candidates | Sort-Object lastSeenAt -Descending | Select-Object -First ([int]$policy.storage.maxCandidates)); rawPromptStored=$false }) 12
    Write-UserAdaptationJson $paths.profile $profileObject 12 -Compact
    $state = Get-UserAdaptationState $Root $WorkspaceRoot
    $state.updatedAt = $now
    $state | Add-Member -NotePropertyName lastSynthesisAt -NotePropertyValue $now -Force
    $state | Add-Member -NotePropertyName rawPromptStored -NotePropertyValue $false -Force
    Write-UserAdaptationJson $paths.state $state 8
    return [pscustomobject]@{ ok=$true; action='Synthesize'; observationCount=$observations.Count; candidateCount=$candidates.Count; activePreferenceCount=@($entries|Where-Object{$_.status-eq'active'}).Count; promotedPreferenceIds=@($promoted); profilePressure=$profilePressure; profileChars=($profileObject|ConvertTo-Json -Depth 12 -Compress).Length; rawPromptStored=$false }
  } 5000 120
  return $result
}

function Get-UserAdaptationPacket {
  param(
    [string]$Root,
    [ValidateSet('general','coding','debugging','planning','review','design','release')][string]$Context='general',
    [string]$WorkspaceKey='',
    [string]$WorkflowKey='',
    [string]$WorkspaceRoot=''
  )
  $activePaths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  if (Test-Path -LiteralPath $activePaths.storeV2 -PathType Leaf) { return Get-UserAdaptationPacketV2 -Root $Root -Context $Context -WorkspaceKey $WorkspaceKey -WorkflowKey $WorkflowKey -WorkspaceRoot $WorkspaceRoot }
  $policy = Get-UserAdaptationPolicy $Root
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  $state = Get-UserAdaptationState $Root $WorkspaceRoot
  if ($state.enabled -ne $true) { return [pscustomobject]@{ ok=$true; action='Packet'; enabled=$false; applies=$false; context=$Context; directiveCount=0; tokenEstimate=0; directives=@(); preferences=@(); rawPromptStored=$false; guard=[string]$policy.authority } }
  $defaults = New-UserAdaptationStoreDefaults
  $profile = Read-UserAdaptationJson $paths.profile $defaults.profile
  $workspaceKeyNormalized = ([string]$WorkspaceKey).ToLowerInvariant()
  $workflowKeyNormalized = ([string]$WorkflowKey).ToLowerInvariant()
  $scopedWorkflowKey = if ([string]::IsNullOrWhiteSpace($workspaceKeyNormalized) -or [string]::IsNullOrWhiteSpace($workflowKeyNormalized)) { '' } else { "$workspaceKeyNormalized`:$workflowKeyNormalized" }
  $matching = @($profile.entries | Where-Object {
    if ($_.status -ne 'active' -or [double]$_.confidence -lt [double]$policy.packet.minimumConfidence) { return $false }
    $rule = Get-UserAdaptationHabitRule $policy ([string]$_.habitKey) ([string]$_.value)
    if (@($rule.contexts).Count -gt 0 -and @($rule.contexts) -notcontains $Context) { return $false }
    $scopeMatch = ($_.scope -eq 'global') -or ($_.scope -eq 'project' -and -not [string]::IsNullOrWhiteSpace($workspaceKeyNormalized) -and $_.scopeKey -eq $workspaceKeyNormalized) -or ($_.scope -eq 'workflow' -and -not [string]::IsNullOrWhiteSpace($workflowKeyNormalized) -and ($_.scopeKey -eq $workflowKeyNormalized -or $_.scopeKey -eq $scopedWorkflowKey))
    if (-not $scopeMatch) { return $false }
    return ($_.source -eq 'explicit_user' -or @($_.contexts) -contains $Context -or @($_.contexts) -contains 'general')
  })
  $rank = @{global=1;project=2;workflow=3}
  $selected = New-Object Collections.ArrayList
  foreach ($group in @($matching | Group-Object habitKey)) {
    $winner = @($group.Group | Sort-Object @{Expression={[int]$rank[[string]$_.scope]};Descending=$true}, @{Expression='confidence';Descending=$true}, @{Expression='updatedAt';Descending=$true} | Select-Object -First 1)[0]
    if ($winner) { [void]$selected.Add($winner) }
  }
  $directives = New-Object Collections.ArrayList
  $preferences = New-Object Collections.ArrayList
  $chars = 0
  foreach ($entry in @($selected | Sort-Object @{Expression={[int]$rank[[string]$_.scope]};Descending=$true}, @{Expression='confidence';Descending=$true})) {
    $rule = Get-UserAdaptationHabitRule $policy ([string]$entry.habitKey) ([string]$entry.value)
    $projectedChars = $chars + $rule.directive.Length
    if ($directives.Count -ge [int]$policy.packet.maxDirectives -or [Math]::Ceiling($projectedChars/4.0) -gt [int]$policy.packet.maxTokens) { continue }
    [void]$directives.Add($rule.directive)
    [void]$preferences.Add([pscustomobject]@{ preferenceId=$entry.preferenceId; habitKey=$entry.habitKey; value=$entry.value; scope=$entry.scope; confidence=$entry.confidence })
    $chars = $projectedChars
  }
  return [pscustomobject]@{ ok=$true; action='Packet'; enabled=$true; applies=($directives.Count-gt0); context=$Context; directiveCount=$directives.Count; tokenEstimate=[int][Math]::Ceiling($chars/4.0); directives=@($directives); preferences=@($preferences); rawPromptStored=$false; guard=[string]$policy.authority }
}

function Set-UserAdaptationEnabled([string]$Root,[bool]$Enabled,[string]$WorkspaceRoot='',[int]$ExpectedRevision=-1,[string]$TransitionId='') {
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  if (Test-Path -LiteralPath $paths.storeV2 -PathType Leaf) { return Set-UserAdaptationEnabledV2 -Root $Root -Enabled $Enabled -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId }
  throw 'USER_ADAPTATION_V2_MIGRATION_REQUIRED'
  New-Item -ItemType Directory -Force -Path $paths.directory | Out-Null
  $state = [pscustomobject]@{ schema='super-brain.user-adaptation-state.v1'; enabled=$Enabled; updatedAt=(Get-Date).ToString('o'); rawPromptStored=$false }
  Write-UserAdaptationJson $paths.state $state 8
  return [pscustomobject]@{ ok=$true; action=if($Enabled){'Enable'}else{'Disable'}; enabled=$Enabled; rawPromptStored=$false }
}

function Remove-UserAdaptationPreference([string]$Root,[string]$PreferenceId,[string]$WorkspaceRoot='',[int]$ExpectedRevision=-1,[string]$TransitionId='',[switch]$Confirmed) {
  if ([string]::IsNullOrWhiteSpace($PreferenceId)) { throw 'USER_ADAPTATION_PREFERENCE_ID_REQUIRED' }
  $policy = Get-UserAdaptationPolicy $Root
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  if (Test-Path -LiteralPath $paths.storeV2 -PathType Leaf) { return Remove-UserAdaptationPreferenceV2 -Root $Root -PreferenceId $PreferenceId -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId -Confirmed:$Confirmed }
  throw 'USER_ADAPTATION_V2_MIGRATION_REQUIRED'
  New-Item -ItemType Directory -Force -Path $paths.directory | Out-Null
  $result = Invoke-SuperBrainFileLock $paths.coordination {
    $defaults = New-UserAdaptationStoreDefaults
    $profile = Read-UserAdaptationJson $paths.profile $defaults.profile
    $target = @($profile.entries | Where-Object { $_.preferenceId -eq $PreferenceId } | Select-Object -First 1)
    if (-not $target) { return [pscustomobject]@{ok=$true;action='Forget';found=$false;preferenceId=$PreferenceId;rawPromptStored=$false} }
    $observations = Read-UserAdaptationJson $paths.observations $defaults.observations
    $candidates = Read-UserAdaptationJson $paths.candidates $defaults.candidates
    $tombstones = Read-UserAdaptationJson $paths.tombstones $defaults.tombstones
    $profile.entries = @($profile.entries | Where-Object { $_.preferenceId -ne $PreferenceId })
    $observations.items = @($observations.items | Where-Object { -not ($_.scope -eq $target.scope -and $_.scopeKey -eq $target.scopeKey -and $_.habitKey -eq $target.habitKey -and $_.value -eq $target.value) })
    $candidates.items = @($candidates.items | Where-Object { $_.preferenceId -ne $PreferenceId })
    $tombstones.items = @(@($tombstones.items) + [pscustomobject]@{ preferenceHash=(Get-UserAdaptationHash $PreferenceId); forgottenAt=(Get-Date).ToString('o') } | Select-Object -Last ([int]$policy.storage.maxTombstones))
    $now=(Get-Date).ToString('o'); $profile.updatedAt=$now; $observations.updatedAt=$now; $candidates.updatedAt=$now; $tombstones.updatedAt=$now
    Write-UserAdaptationJson $paths.profile $profile 12 -Compact
    Write-UserAdaptationJson $paths.observations $observations 12
    Write-UserAdaptationJson $paths.candidates $candidates 12
    Write-UserAdaptationJson $paths.tombstones $tombstones 8
    return [pscustomobject]@{ok=$true;action='Forget';found=$true;preferenceId=$PreferenceId;rawPromptStored=$false}
  } 5000 120
  return $result
}

function Get-UserAdaptationStatus([string]$Root,[string]$WorkspaceRoot='') {
  $policy=Get-UserAdaptationPolicy $Root; $paths=Get-UserAdaptationPaths $Root $WorkspaceRoot; if(Test-Path -LiteralPath $paths.storeV2 -PathType Leaf){return Get-UserAdaptationStatusV2 $Root $WorkspaceRoot}; $defaults=New-UserAdaptationStoreDefaults
  $state=Get-UserAdaptationState $Root $WorkspaceRoot; $observations=Read-UserAdaptationJson $paths.observations $defaults.observations; $candidates=Read-UserAdaptationJson $paths.candidates $defaults.candidates; $profile=Read-UserAdaptationJson $paths.profile $defaults.profile
  return [pscustomobject]@{ok=$true;action='Status';schema='super-brain.user-adaptation-status.v1';enabled=[bool]$state.enabled;observationCount=@($observations.items).Count;candidateCount=@($candidates.items).Count;activePreferenceCount=@($profile.entries|Where-Object{$_.status-eq'active'}).Count;profileChars=if(Test-Path -LiteralPath $paths.profile){(Get-Item -LiteralPath $paths.profile).Length}else{0};profilePressure=[string]$profile.profilePressure;budgets=[pscustomobject]@{maxObservations=[int]$policy.storage.maxObservations;maxCandidates=[int]$policy.storage.maxCandidates;maxStablePreferences=[int]$policy.storage.maxStablePreferences;maxProfileChars=[int]$policy.storage.maxProfileChars;maxDirectives=[int]$policy.packet.maxDirectives;maxTokens=[int]$policy.packet.maxTokens};rawPromptStored=$false;directory=$paths.directory}
}
