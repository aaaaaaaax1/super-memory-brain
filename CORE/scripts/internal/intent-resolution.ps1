function Get-IntentResolutionProperty([object]$Value,[string]$Name) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
  $property = $Value.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

function Get-IntentResolutionText([object]$Value,[string]$Name,[int]$Max = 240) {
  $raw = Get-IntentResolutionProperty $Value $Name
  if ($null -eq $raw) { return '' }
  $text = [string]$raw
  if (Get-Command Protect-Instruction -ErrorAction SilentlyContinue) { $text = Protect-Instruction $text }
  return Limit-ContractText $text $Max
}

function Get-IntentResolutionList([object]$Value,[string]$Name,[int]$MaxItems = 8,[int]$MaxChars = 180) {
  $raw = Get-IntentResolutionProperty $Value $Name
  if ($null -eq $raw) { return @() }
  return @(Limit-ContractList @($raw) $MaxItems $MaxChars)
}

function Get-IntentResolutionIntegrationMap([object]$Value) {
  $map = Get-IntentResolutionProperty $Value 'integrationMap'
  if (-not $map) { return $null }
  return [pscustomobject]@{
    entryPoint = Get-IntentResolutionText $map 'entryPoint' 240
    userFlow = Get-IntentResolutionText $map 'userFlow' 240
    domainOwner = Get-IntentResolutionText $map 'domainOwner' 240
    stateOwner = Get-IntentResolutionText $map 'stateOwner' 240
    downstreamConsumers = @(Get-IntentResolutionList $map 'downstreamConsumers' 8 180)
    failureRecovery = Get-IntentResolutionText $map 'failureRecovery' 240
    privacyPerformance = Get-IntentResolutionText $map 'privacyPerformance' 240
    compatibilityMigration = Get-IntentResolutionText $map 'compatibilityMigration' 240
    verification = Get-IntentResolutionText $map 'verification' 240
    completionCondition = Get-IntentResolutionText $map 'completionCondition' 240
  }
}

function Get-IntentResolutionContractPayload([object]$IntentContract) {
  $schema = if ($IntentContract -and [string]$IntentContract.schema -eq 'super-brain.intent-contract.v2') { 'super-brain.intent-contract.v2' } else { 'super-brain.intent-contract.v1' }
  $payload = [ordered]@{
    schema = $schema
    literalRequestDigest = [string]$IntentContract.literalRequestDigest
    resolvedOutcome = [string]$IntentContract.resolvedOutcome
    productRole = [string]$IntentContract.productRole
    integrationObligations = @($IntentContract.integrationObligations)
    materialUnknowns = @($IntentContract.materialUnknowns)
    compatibilityGuards = @($IntentContract.compatibilityGuards)
    preservedCapabilities = @($IntentContract.preservedCapabilities)
    acceptanceCriteria = @($IntentContract.acceptanceCriteria)
    governedEquivalent = [string]$IntentContract.governedEquivalent
    autonomyTier = [string]$IntentContract.autonomyTier
  }
  if ($schema -eq 'super-brain.intent-contract.v2') {
    $payload.integrationMap = $IntentContract.integrationMap
    $payload.investigationEvidence = @($IntentContract.investigationEvidence)
    $payload.materialBranches = @($IntentContract.materialBranches)
    $payload.focusedQuestion = [string]$IntentContract.focusedQuestion
    $payload.questionCount = [int]$IntentContract.questionCount
    $payload.preserveExistingFlow = [bool]$IntentContract.preserveExistingFlow
    $payload.replacementReceipt = [string]$IntentContract.replacementReceipt
    $payload.componentResolution = $IntentContract.componentResolution
  }
  return $payload
}

function ConvertTo-IntentResolutionContract([object]$Value,[switch]$RequireCurrentSchema) {
  $candidate = $Value
  if ($candidate -is [string]) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_CONTRACT_REQUIRED'; intentContract=$null; missing=@('IntentContractJson') }
    }
    try { $candidate = ([string]$candidate | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_CONTRACT_JSON_INVALID'; intentContract=$null; missing=@('valid JSON') } }
  }
  if ($null -eq $candidate -or $candidate -is [System.Collections.IEnumerable] -and $candidate -isnot [string] -and $candidate -isnot [pscustomobject]) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_CONTRACT_INVALID'; intentContract=$null; missing=@('intent contract object') }
  }

  $schema = Get-IntentResolutionText $candidate 'schema' 64
  if ([string]::IsNullOrWhiteSpace($schema)) { $schema = 'super-brain.intent-contract.v1' }
  if ($schema -notin @('super-brain.intent-contract.v1','super-brain.intent-contract.v2')) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_CONTRACT_SCHEMA_INVALID'; intentContract=$null; missing=@('supported schema') }
  }
  if ($RequireCurrentSchema -and $schema -ne 'super-brain.intent-contract.v2') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_CONTRACT_UPGRADE_REQUIRED'; intentContract=$null; missing=@('super-brain.intent-contract.v2') }
  }

  $literalRequestDigest = Get-IntentResolutionText $candidate 'literalRequestDigest' 240
  if ([string]::IsNullOrWhiteSpace($literalRequestDigest)) { $literalRequestDigest = Get-IntentResolutionText $candidate 'literalRequest' 240 }
  $resolvedOutcome = Get-IntentResolutionText $candidate 'resolvedOutcome' 280
  $productRole = Get-IntentResolutionText $candidate 'productRole' 220
  $integrationObligations = @(Get-IntentResolutionList $candidate 'integrationObligations' 8 180)
  $materialUnknowns = @(Get-IntentResolutionList $candidate 'materialUnknowns' 4 180)
  $compatibilityGuards = @(Get-IntentResolutionList $candidate 'compatibilityGuards' 8 180)
  $preservedCapabilities = @(Get-IntentResolutionList $candidate 'preservedCapabilities' 8 180)
  $acceptanceCriteria = @(Get-IntentResolutionList $candidate 'acceptanceCriteria' 8 180)
  if ($acceptanceCriteria.Count -eq 0) { $acceptanceCriteria = @(Get-IntentResolutionList $candidate 'acceptance' 8 180) }
  $governedEquivalent = Get-IntentResolutionText $candidate 'governedEquivalent' 220
  $autonomyTier = (Get-IntentResolutionText $candidate 'autonomyTier' 24).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($autonomyTier)) { $autonomyTier = 'align' }

  $missing = @()
  if ([string]::IsNullOrWhiteSpace($literalRequestDigest)) { $missing += 'literalRequestDigest' }
  if ([string]::IsNullOrWhiteSpace($resolvedOutcome)) { $missing += 'resolvedOutcome' }
  if ([string]::IsNullOrWhiteSpace($productRole)) { $missing += 'productRole' }
  if ($integrationObligations.Count -eq 0) { $missing += 'integrationObligations' }
  if ($compatibilityGuards.Count -eq 0 -and $schema -eq 'super-brain.intent-contract.v2') { $missing += 'compatibilityGuards' }
  if ($preservedCapabilities.Count -eq 0) { $missing += 'preservedCapabilities' }
  if ($acceptanceCriteria.Count -eq 0) { $missing += 'acceptanceCriteria' }
  if ($autonomyTier -notin @('direct','align','discuss')) { $missing += 'autonomyTier' }

  $integrationMap = Get-IntentResolutionIntegrationMap $candidate
  $investigationEvidence = @(Get-IntentResolutionList $candidate 'investigationEvidence' 8 220)
  $materialBranches = @(Get-IntentResolutionList $candidate 'materialBranches' 4 180)
  $focusedQuestion = Get-IntentResolutionText $candidate 'focusedQuestion' 240
  $preserveExistingFlowValue = Get-IntentResolutionProperty $candidate 'preserveExistingFlow'
  $replacementReceipt = Get-IntentResolutionText $candidate 'replacementReceipt' 180
  $component = Get-IntentResolutionProperty $candidate 'componentResolution'
  if ($schema -eq 'super-brain.intent-contract.v2') {
    if (-not $integrationMap) { $missing += 'integrationMap' } else {
      foreach ($name in @('entryPoint','userFlow','domainOwner','stateOwner','failureRecovery','privacyPerformance','compatibilityMigration','verification','completionCondition')) {
        if ([string]::IsNullOrWhiteSpace([string]$integrationMap.$name)) { $missing += ('integrationMap.' + $name) }
      }
      if (@($integrationMap.downstreamConsumers).Count -eq 0) { $missing += 'integrationMap.downstreamConsumers' }
    }
    if ($investigationEvidence.Count -eq 0) { $missing += 'investigationEvidence' }
    if ($null -eq $preserveExistingFlowValue -or $preserveExistingFlowValue -isnot [bool]) { $missing += 'preserveExistingFlow' }
    elseif ($preserveExistingFlowValue -eq $false -and [string]::IsNullOrWhiteSpace($replacementReceipt)) { $missing += 'replacementReceipt' }
    if ($materialBranches.Count -ge 2 -and [string]::IsNullOrWhiteSpace($focusedQuestion)) { $missing += 'focusedQuestion' }
  }
  if ($missing.Count -gt 0) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_CONTRACT_INCOMPLETE'; intentContract=$null; missing=@($missing | Select-Object -Unique) }
  }

  $allText = ($literalRequestDigest + ' ' + $resolvedOutcome + ' ' + $productRole + ' ' + ($preservedCapabilities -join ' ') + ' ' + $governedEquivalent).ToLowerInvariant()
  $editableNoDirectDatabase = ($literalRequestDigest -match '(?i)editable|\bedit\b' -and $literalRequestDigest -match '(?i)(database|\bdb\b|sqlite)' -and $literalRequestDigest -match '(?i)(no\s+direct|without\s+direct)')
  if ($editableNoDirectDatabase) {
    $preservesEditing = $allText -match '(?i)editable|\bedit(?:ing)?\b'
    $hasGovernedPath = $allText -match '(?i)governed|command|\bapi\b|service'
    $degradesToReadOnly = $allText -match '(?i)read[ -]?only'
    $hasDirectDatabaseGuard = @($compatibilityGuards | Where-Object { [string]$_ -match '(?i)(no|without).{0,24}(browser|ui|client).{0,24}(direct).{0,24}(database|db|sqlite)' }).Count -gt 0
    if (-not $preservesEditing -or -not $hasGovernedPath -or $degradesToReadOnly -or ($schema -eq 'super-brain.intent-contract.v2' -and -not $hasDirectDatabaseGuard)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_GOVERNED_EQUIVALENT_REQUIRED'; intentContract=$null; missing=@('editable capability through a governed command/API path with no browser-side database access') }
    }
  }

  $componentResolution = if ($schema -eq 'super-brain.intent-contract.v2') {
    [pscustomobject]@{
      requestedComponent = Get-IntentResolutionText $component 'requestedComponent' 160
      resolvedComponent = Get-IntentResolutionText $component 'resolvedComponent' 160
      outcomePreserved = if ($component -and (Get-IntentResolutionProperty $component 'outcomePreserved') -is [bool]) { [bool](Get-IntentResolutionProperty $component 'outcomePreserved') } else { $true }
      reason = Get-IntentResolutionText $component 'reason' 220
    }
  } else { $null }
  if ($componentResolution -and -not [string]::IsNullOrWhiteSpace($componentResolution.requestedComponent) -and -not [string]::IsNullOrWhiteSpace($componentResolution.resolvedComponent) -and $componentResolution.requestedComponent -ne $componentResolution.resolvedComponent -and (-not $componentResolution.outcomePreserved -or [string]::IsNullOrWhiteSpace($componentResolution.reason))) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_COMPONENT_REMAP_INVALID'; intentContract=$null; missing=@('outcome-preserving component remap reason') }
  }

  $intentContract = [pscustomobject]@{
    schema = $schema
    literalRequestDigest = $literalRequestDigest
    resolvedOutcome = $resolvedOutcome
    productRole = $productRole
    integrationObligations = @($integrationObligations)
    materialUnknowns = @($materialUnknowns)
    compatibilityGuards = @($compatibilityGuards)
    preservedCapabilities = @($preservedCapabilities)
    acceptanceCriteria = @($acceptanceCriteria)
    governedEquivalent = $governedEquivalent
    autonomyTier = $autonomyTier
    rawTranscriptStored = $false
  }
  if ($schema -eq 'super-brain.intent-contract.v2') {
    $intentContract | Add-Member -NotePropertyName integrationMap -NotePropertyValue $integrationMap -Force
    $intentContract | Add-Member -NotePropertyName investigationEvidence -NotePropertyValue @($investigationEvidence) -Force
    $intentContract | Add-Member -NotePropertyName materialBranches -NotePropertyValue @($materialBranches) -Force
    $intentContract | Add-Member -NotePropertyName focusedQuestion -NotePropertyValue $focusedQuestion -Force
    $intentContract | Add-Member -NotePropertyName questionCount -NotePropertyValue $(if([string]::IsNullOrWhiteSpace($focusedQuestion)){0}else{1}) -Force
    $intentContract | Add-Member -NotePropertyName preserveExistingFlow -NotePropertyValue ([bool]$preserveExistingFlowValue) -Force
    $intentContract | Add-Member -NotePropertyName replacementReceipt -NotePropertyValue $replacementReceipt -Force
    $intentContract | Add-Member -NotePropertyName componentResolution -NotePropertyValue $componentResolution -Force
  }
  if ($candidate.PSObject.Properties['contractFingerprint'] -and [string]$candidate.contractFingerprint -match '^[a-f0-9]{64}$') {
    $intentContract | Add-Member -NotePropertyName contractFingerprint -NotePropertyValue ([string]$candidate.contractFingerprint) -Force
  }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_INTENT_CONTRACT_OK'; intentContract=$intentContract; missing=@() }
}

function Get-IntentControlPython {
  $command = Get-Command python -ErrorAction SilentlyContinue
  if (-not $command) { return '' }
  if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) { return [string]$command.Source }
  return [string]$command.Name
}

function ConvertTo-IntentResolutionPublicCode([string]$Code,[string]$Fallback) {
  if ([string]::IsNullOrWhiteSpace($Code)) { return $Fallback }
  if ($Code.StartsWith('BRAIN_CONTROL_INTENT_',[System.StringComparison]::Ordinal)) {
    return ('EXECUTION_CONTRACT_INTENT_' + $Code.Substring('BRAIN_CONTROL_INTENT_'.Length))
  }
  if ($Code -eq 'BRAIN_CONTROL_COMMAND_ID_REUSED') {
    return 'EXECUTION_CONTRACT_INTENT_COMMAND_ID_REUSED'
  }
  return $Code
}

function Invoke-IntentControlPlane([ValidateSet('prepare-intent','resolve-intent','check-intent','rebind-intent')][string]$Action,[object]$Request) {
  $python = Get-IntentControlPython
  $runtime = Join-Path $Root 'runtime\brain_control.py'
  if ([string]::IsNullOrWhiteSpace($python) -or -not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; current=$false; code='EXECUTION_CONTRACT_INTENT_CONTROL_PLANE_UNAVAILABLE'; missing=@('local BrainControl Python runtime') }
  }
  try {
    $json = $Request | ConvertTo-Json -Depth 16 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $raw = @(& $python -B $runtime --state-root $memoryBase $Action --request-base64 $encoded 2>&1)
    $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'empty BrainControl response' }
    return ConvertFrom-SuperBrainJsonOutput $text ('intent control plane ' + $Action)
  } catch {
    return [pscustomobject]@{ ok=$false; current=$false; code='EXECUTION_CONTRACT_INTENT_CONTROL_PLANE_FAILED'; missing=@(Limit-ContractText $_.Exception.Message 180) }
  }
}

function Invoke-TaskSessionControlPlane([ValidateSet('rebind-task-session')][string]$Action,[object]$Request) {
  $python = Get-IntentControlPython
  $runtime = Join-Path $Root 'runtime\brain_control.py'
  if ([string]::IsNullOrWhiteSpace($python) -or -not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TASK_SESSION_REBIND_CONTROL_PLANE_UNAVAILABLE'; missing=@('local BrainControl Python runtime') }
  }
  try {
    $json = $Request | ConvertTo-Json -Depth 16 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $raw = @(& $python -B $runtime --state-root $memoryBase $Action --request-base64 $encoded 2>&1)
    $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'empty BrainControl response' }
    return ConvertFrom-SuperBrainJsonOutput $text ('task session control plane ' + $Action)
  } catch {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TASK_SESSION_REBIND_CONTROL_PLANE_FAILED'; missing=@(Limit-ContractText $_.Exception.Message 180) }
  }
}

function Prepare-IntentResolution([string]$TaskIdValue,[string]$TaskInstanceIdValue,[string]$WorkspaceKeyValue,[string]$OwnerSessionKeyValue,[object]$IntentContractValue) {
  $normalized = ConvertTo-IntentResolutionContract $IntentContractValue -RequireCurrentSchema
  if (-not $normalized.ok) { return $normalized }
  $request = [ordered]@{
    taskId=$TaskIdValue;taskInstanceId=$TaskInstanceIdValue;workspaceKey=$WorkspaceKeyValue;ownerSessionKey=$OwnerSessionKeyValue
    intentContract=Get-IntentResolutionContractPayload $normalized.intentContract
  }
  $prepared = Invoke-IntentControlPlane 'prepare-intent' $request
  if (-not $prepared -or $prepared.ok -ne $true) {
    return [pscustomobject]@{ ok=$false; code=if($prepared){ConvertTo-IntentResolutionPublicCode ([string]$prepared.code) 'EXECUTION_CONTRACT_INTENT_PREPARE_FAILED'}else{'EXECUTION_CONTRACT_INTENT_PREPARE_FAILED'}; intentContract=$null; missing=if($prepared){@($prepared.missing)}else{@('BrainControl prepare result')} }
  }
  $contract = $prepared.intentContract
  $contract | Add-Member -NotePropertyName contractFingerprint -NotePropertyValue ([string]$prepared.intentContractFingerprint) -Force
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_INTENT_PREPARED'; aggregateId=[string]$prepared.aggregateId; expectedIntentRevision=[int]$prepared.expectedIntentRevision; intentRevision=[int]$prepared.intentRevision; contractChanged=[bool]$prepared.contractChanged; ready=[bool]$prepared.ready; intentContract=$contract; missing=@() }
}

function Rebind-IntentResolution([string]$TaskIdValue,[string]$TaskInstanceIdValue,[string]$WorkspaceKeyValue,[string]$PreviousOwnerSessionKeyValue,[string]$NewOwnerSessionKeyValue,[int]$ExpectedIntentRevisionValue,[object]$PreviousReceipt,[string]$SourceValue) {
  if (-not $PreviousReceipt -or [string]::IsNullOrWhiteSpace([string]$PreviousReceipt.receiptId) -or [string]$PreviousReceipt.payloadHash -notmatch '^[a-f0-9]{64}$') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_REBIND_RECEIPT_REQUIRED'; missing=@('current immutable intent receipt') }
  }
  if ([string]::IsNullOrWhiteSpace($PreviousOwnerSessionKeyValue) -or [string]::IsNullOrWhiteSpace($NewOwnerSessionKeyValue) -or $ExpectedIntentRevisionValue -lt 1) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_REBIND_SCOPE_INVALID'; missing=@('previous session, new session, and intent revision') }
  }
  $commandMaterial = @($TaskIdValue,$TaskInstanceIdValue,$WorkspaceKeyValue,$PreviousOwnerSessionKeyValue,$NewOwnerSessionKeyValue,$ExpectedIntentRevisionValue,[string]$PreviousReceipt.receiptId,[string]$PreviousReceipt.payloadHash) -join '|'
  $request = [ordered]@{
    commandId='intent-session-rebind-' + (Get-SuperBrainStableHash $commandMaterial 48)
    taskId=$TaskIdValue;taskInstanceId=$TaskInstanceIdValue;workspaceKey=$WorkspaceKeyValue
    previousOwnerSessionKey=$PreviousOwnerSessionKeyValue;newOwnerSessionKey=$NewOwnerSessionKeyValue
    expectedIntentRevision=$ExpectedIntentRevisionValue;latestReceiptId=[string]$PreviousReceipt.receiptId;latestReceiptPayloadHash=[string]$PreviousReceipt.payloadHash
    source=Limit-ContractText $SourceValue 120
  }
  $rebound = Invoke-IntentControlPlane 'rebind-intent' $request
  if (-not $rebound -or $rebound.ok -ne $true) {
    return [pscustomobject]@{ ok=$false; code=if($rebound){ConvertTo-IntentResolutionPublicCode ([string]$rebound.code) 'EXECUTION_CONTRACT_INTENT_REBIND_FAILED'}else{'EXECUTION_CONTRACT_INTENT_REBIND_FAILED'}; missing=if($rebound){@($rebound.missing)}else{@('BrainControl rebind result')} }
  }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_INTENT_REBOUND'; aggregateId=[string]$rebound.aggregateId; receipt=$rebound; missing=@() }
}

function Issue-TaskSessionRebindReceipt([string]$TaskIdValue,[string]$TaskInstanceIdValue,[string]$WorkspaceKeyValue,[string]$PreviousOwnerSessionKeyValue,[string]$NewOwnerSessionKeyValue,[string]$PackageVersionValue,[int]$ExpectedTaskRevisionValue,[int]$ExpectedContractRevisionValue,[string]$ExpectedPlanFingerprintValue,[string]$SourceValue) {
  if ([string]::IsNullOrWhiteSpace($TaskIdValue) -or [string]::IsNullOrWhiteSpace($TaskInstanceIdValue) -or [string]::IsNullOrWhiteSpace($WorkspaceKeyValue) -or [string]::IsNullOrWhiteSpace($PreviousOwnerSessionKeyValue) -or [string]::IsNullOrWhiteSpace($NewOwnerSessionKeyValue) -or [string]::IsNullOrWhiteSpace($PackageVersionValue) -or [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprintValue) -or $ExpectedTaskRevisionValue -lt 0 -or $ExpectedContractRevisionValue -lt 1) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TASK_SESSION_REBIND_SCOPE_INVALID'; missing=@('task scope, both owners, package version, current task revision, prior contract revision, and plan fingerprint') }
  }
  if ([string]::Equals($PreviousOwnerSessionKeyValue,$NewOwnerSessionKeyValue,[StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TASK_SESSION_REBIND_OWNER_UNCHANGED'; missing=@('a different successor owner') }
  }
  $commandMaterial = @($TaskIdValue,$TaskInstanceIdValue,$WorkspaceKeyValue,$PreviousOwnerSessionKeyValue,$NewOwnerSessionKeyValue,$PackageVersionValue,$ExpectedTaskRevisionValue,$ExpectedContractRevisionValue,$ExpectedPlanFingerprintValue) -join '|'
  $request = [ordered]@{
    commandId='task-session-rebind-' + (Get-SuperBrainStableHash $commandMaterial 48)
    taskId=$TaskIdValue; taskInstanceId=$TaskInstanceIdValue; workspaceKey=$WorkspaceKeyValue
    previousOwnerSessionKey=$PreviousOwnerSessionKeyValue; newOwnerSessionKey=$NewOwnerSessionKeyValue; packageVersion=$PackageVersionValue
    expectedTaskRevision=$ExpectedTaskRevisionValue; expectedContractRevision=$ExpectedContractRevisionValue; expectedPlanFingerprint=$ExpectedPlanFingerprintValue
    source=Limit-ContractText $SourceValue 120
  }
  $issued = Invoke-TaskSessionControlPlane 'rebind-task-session' $request
  if (-not $issued -or $issued.ok -ne $true) {
    $code = if($issued -and $issued.code){[string]$issued.code}else{'EXECUTION_CONTRACT_TASK_SESSION_REBIND_FAILED'}
    if ($code.StartsWith('BRAIN_CONTROL_TASK_SESSION_REBIND_',[StringComparison]::Ordinal)) { $code = 'EXECUTION_CONTRACT_' + $code.Substring('BRAIN_CONTROL_'.Length) }
    elseif ($code -eq 'BRAIN_CONTROL_COMMAND_ID_REUSED') { $code = 'EXECUTION_CONTRACT_TASK_SESSION_REBIND_COMMAND_ID_REUSED' }
    return [pscustomobject]@{ ok=$false; code=$code; missing=if($issued){@($issued.missing)}else{@('BrainControl task session rebind result')} }
  }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_TASK_SESSION_REBIND_ISSUED'; aggregateId=[string]$issued.aggregateId; receipt=$issued; missing=@() }
}

function Resolve-IntentResolution([object]$Prepared,[string]$TaskIdValue,[string]$TaskInstanceIdValue,[string]$WorkspaceKeyValue,[string]$OwnerSessionKeyValue,[string]$PackageVersionValue,[int]$RevisionValue,[object]$PlanReceiptValue,[string]$LatestInstructionValue,[string]$SourceValue) {
  if (-not $Prepared -or $Prepared.ok -ne $true -or -not $PlanReceiptValue) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_PREPARE_REQUIRED'; missing=@('prepared intent and plan receipt') } }
  $instructionHash = Get-SuperBrainStableHash ([string]$LatestInstructionValue) 64
  $commandMaterial = @($TaskIdValue,$TaskInstanceIdValue,$WorkspaceKeyValue,$OwnerSessionKeyValue,$PackageVersionValue,$RevisionValue,[string]$PlanReceiptValue.planFingerprint,$instructionHash,[string]$Prepared.intentContract.contractFingerprint) -join '|'
  $request = [ordered]@{
    commandId='intent-resolve-' + (Get-SuperBrainStableHash $commandMaterial 48)
    expectedIntentRevision=[int]$Prepared.expectedIntentRevision
    taskId=$TaskIdValue;taskInstanceId=$TaskInstanceIdValue;workspaceKey=$WorkspaceKeyValue;ownerSessionKey=$OwnerSessionKeyValue
    packageVersion=$PackageVersionValue;contractRevision=$RevisionValue;planFingerprint=[string]$PlanReceiptValue.planFingerprint
    latestInstructionHash=$instructionHash;intentContract=Get-IntentResolutionContractPayload $Prepared.intentContract;source=Limit-ContractText $SourceValue 120
  }
  $resolved = Invoke-IntentControlPlane 'resolve-intent' $request
  if (-not $resolved -or $resolved.ok -ne $true) {
    return [pscustomobject]@{ ok=$false; code=if($resolved){ConvertTo-IntentResolutionPublicCode ([string]$resolved.code) 'EXECUTION_CONTRACT_INTENT_RESOLUTION_FAILED'}else{'EXECUTION_CONTRACT_INTENT_RESOLUTION_FAILED'}; missing=if($resolved){@($resolved.missing)}else{@('BrainControl resolution result')} }
  }
  $contract = $resolved.intentContract
  $contract | Add-Member -NotePropertyName contractFingerprint -NotePropertyValue ([string]$resolved.intentResolutionReceipt.intentContractFingerprint) -Force
  return [pscustomobject]@{ ok=$true; code=[string]$resolved.code; aggregateId=[string]$resolved.aggregateId; intentRevision=[int]$resolved.intentRevision; intentContract=$contract; intentResolutionReceipt=$resolved.intentResolutionReceipt; missing=@() }
}

function Test-IntentResolutionReceiptRequired([object]$Contract,[switch]$Force) {
  return ([bool]$Force -or ($Contract -and $Contract.PSObject.Properties['intentContractRequired'] -and $Contract.intentContractRequired -eq $true))
}

function Get-IntentResolutionReceiptStatus([object]$Contract,[switch]$Force) {
  $required = Test-IntentResolutionReceiptRequired $Contract -Force:$Force
  if (-not $required) { return [pscustomobject]@{ required=$false; current=$true; code='EXECUTION_CONTRACT_INTENT_RECEIPT_NOT_REQUIRED'; missing=@(); receipt=$null; intentContract=$null } }
  if (-not $Contract) { return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_CONTRACT_MISSING'; missing=@('execution contract'); receipt=$null; intentContract=$null } }
  $normalized = ConvertTo-IntentResolutionContract (Get-IntentResolutionProperty $Contract 'intentContract') -RequireCurrentSchema
  if (-not $normalized.ok) { return [pscustomobject]@{ required=$true; current=$false; code=[string]$normalized.code; missing=@($normalized.missing); receipt=$null; intentContract=$null } }
  $receipt = Get-IntentResolutionProperty $Contract 'intentResolutionReceipt'
  if (-not $receipt) { return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_REQUIRED'; missing=@('intentResolutionReceipt'); receipt=$null; intentContract=$normalized.intentContract } }
  if ([string]$receipt.schema -ne 'super-brain.intent-resolution-receipt.v2') { return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_SCHEMA_INVALID'; missing=@('super-brain.intent-resolution-receipt.v2'); receipt=$receipt; intentContract=$normalized.intentContract } }
  $planReceipt = Get-IntentResolutionProperty $Contract 'planReceipt'
  if (-not $planReceipt -or [string]::IsNullOrWhiteSpace([string]$planReceipt.planFingerprint)) { return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_INTENT_PLAN_RECEIPT_REQUIRED'; missing=@('planReceipt'); receipt=$receipt; intentContract=$normalized.intentContract } }
  $intentRevision = if ($Contract.PSObject.Properties['intentRevision']) { [int]$Contract.intentRevision } else { 0 }
  $intentBinding = if ($planReceipt.PSObject.Properties['intentBinding']) { $planReceipt.intentBinding } else { $null }
  $localMissing = @()
  if ($intentRevision -lt 1 -or [int]$receipt.intentRevision -ne $intentRevision) { $localMissing += 'intentRevision' }
  if (-not $intentBinding -or [int]$intentBinding.intentRevision -ne $intentRevision -or [string]$intentBinding.intentContractFingerprint -ne [string]$receipt.intentContractFingerprint) { $localMissing += 'planIntentBinding' }
  if ([string]$normalized.intentContract.contractFingerprint -ne [string]$receipt.intentContractFingerprint) { $localMissing += 'intentContractFingerprint' }
  if ($localMissing.Count -gt 0) { return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_STALE'; missing=@($localMissing); receipt=$receipt; intentContract=$normalized.intentContract } }
  $instructionHash = Get-SuperBrainStableHash ([string]$Contract.latestUserInstruction) 64
  $request = [ordered]@{
    taskId=[string]$Contract.taskId;taskInstanceId=[string]$Contract.taskInstanceId;workspaceKey=[string]$Contract.workspaceKey;ownerSessionKey=[string]$Contract.ownerSessionKey
    packageVersion=[string]$Contract.packageVersion;contractRevision=[int]$Contract.revision;intentRevision=$intentRevision;planFingerprint=[string]$planReceipt.planFingerprint
    latestInstructionHash=$instructionHash;intentContractFingerprint=[string]$receipt.intentContractFingerprint;receiptId=[string]$receipt.receiptId;payloadHash=[string]$receipt.payloadHash
  }
  $checked = Invoke-IntentControlPlane 'check-intent' $request
  if (-not $checked -or $checked.ok -ne $true -or $checked.current -ne $true) {
    return [pscustomobject]@{ required=$true; current=$false; code=if($checked){ConvertTo-IntentResolutionPublicCode ([string]$checked.code) 'EXECUTION_CONTRACT_INTENT_RECEIPT_INVALID'}else{'EXECUTION_CONTRACT_INTENT_RECEIPT_INVALID'}; missing=if($checked){@($checked.missing)}else{@('BrainControl receipt check')}; receipt=$receipt; intentContract=$normalized.intentContract }
  }
  return [pscustomobject]@{ required=$true; current=$true; code='EXECUTION_CONTRACT_INTENT_RECEIPT_CURRENT'; missing=@(); receipt=$receipt; intentContract=$checked.intentContract }
}

function Test-IntentResolutionReceiptCurrent([object]$Contract,[switch]$Force) {
  return (Get-IntentResolutionReceiptStatus $Contract -Force:$Force).current
}

function Normalize-SuperBrainIntentFulfillmentText([object]$Value,[int]$Max = 240) {
  if ($null -eq $Value) { return '' }
  $text = ([string]$Value).Trim() -replace '\s+',' '
  if ($text.Length -gt $Max) { $text = $text.Substring(0,$Max) }
  return $text
}

function Get-SuperBrainIntentRequirements([object]$Contract) {
  if (-not $Contract -or -not $Contract.PSObject.Properties['intentContract'] -or -not $Contract.intentContract) { return @() }
  $intent = $Contract.intentContract
  $requirements = @()
  foreach ($spec in @(
    [pscustomobject]@{ property='integrationObligations'; category='integration_obligation' },
    [pscustomobject]@{ property='preservedCapabilities'; category='preserved_capability' },
    [pscustomobject]@{ property='acceptanceCriteria'; category='acceptance_criterion' }
  )) {
    $ordinal = 0
    foreach ($raw in @($intent.($spec.property))) {
      $text = Normalize-SuperBrainIntentFulfillmentText $raw 240
      if ([string]::IsNullOrWhiteSpace($text)) { continue }
      $ordinal++
      $requirements += [pscustomobject][ordered]@{
        category = [string]$spec.category
        ordinal = $ordinal
        requirement = $text
        requirementHash = Get-SuperBrainStableHash (([string]$spec.category) + '|' + $text.ToLowerInvariant()) 64
      }
    }
  }
  return @($requirements)
}

function Get-SuperBrainIntentRequirementsFingerprint([object[]]$Requirements) {
  $payload = [ordered]@{
    schema = 'super-brain.intent-requirements.v1'
    items = @($Requirements | ForEach-Object {
      [ordered]@{ category=[string]$_.category; ordinal=[int]$_.ordinal; requirementHash=[string]$_.requirementHash }
    })
  }
  return Get-SuperBrainStableHash ($payload | ConvertTo-Json -Depth 8 -Compress) 64
}

function Get-SuperBrainIntentFulfillmentPayload([object]$Record) {
  return [ordered]@{
    schema = 'super-brain.intent-fulfillment.v1'
    required = [bool]$Record.required
    ok = [bool]$Record.ok
    taskId = [string]$Record.taskId
    taskInstanceId = [string]$Record.taskInstanceId
    workspaceKey = [string]$Record.workspaceKey
    ownerSessionKey = [string]$Record.ownerSessionKey
    packageVersion = [string]$Record.packageVersion
    contractRevision = [int]$Record.contractRevision
    intentRevision = [int]$Record.intentRevision
    planFingerprint = [string]$Record.planFingerprint
    intentContractFingerprint = [string]$Record.intentContractFingerprint
    intentReceiptId = [string]$Record.intentReceiptId
    intentReceiptPayloadHash = [string]$Record.intentReceiptPayloadHash
    requirementsFingerprint = [string]$Record.requirementsFingerprint
    items = @($Record.items | ForEach-Object {
      [ordered]@{
        category=[string]$_.category;ordinal=[int]$_.ordinal;requirement=[string]$_.requirement
        requirementHash=[string]$_.requirementHash;ok=[bool]$_.ok;evidenceRefs=@($_.evidenceRefs | ForEach-Object { [string]$_ })
      }
    })
  }
}

function New-SuperBrainIntentFulfillment([object]$Contract,[object]$InputValue) {
  $required = Test-IntentResolutionReceiptRequired $Contract
  if (-not $required) {
    return [pscustomobject]@{ ok=$true; code='TASK_INTENT_FULFILLMENT_NOT_REQUIRED'; required=$false; record=[pscustomobject]@{ schema='super-brain.intent-fulfillment.v1'; required=$false; ok=$true; items=@(); missing=@(); rawPromptStored=$false; rawTranscriptStored=$false } }
  }
  if (-not $Contract) { return [pscustomobject]@{ ok=$false; code='TASK_INTENT_FULFILLMENT_CONTRACT_REQUIRED'; required=$true; record=$null; missing=@('execution contract') } }
  $candidate = $InputValue
  if ($candidate -is [string]) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { return [pscustomobject]@{ ok=$false; code='TASK_INTENT_FULFILLMENT_REQUIRED'; required=$true; record=$null; missing=@('IntentFulfillmentJson') } }
    try { $candidate = ([string]$candidate | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ ok=$false; code='TASK_INTENT_FULFILLMENT_JSON_INVALID'; required=$true; record=$null; missing=@('valid JSON') } }
  }
  if (-not $candidate) { return [pscustomobject]@{ ok=$false; code='TASK_INTENT_FULFILLMENT_REQUIRED'; required=$true; record=$null; missing=@('IntentFulfillmentJson') } }

  $requirements = @(Get-SuperBrainIntentRequirements $Contract)
  if ($requirements.Count -eq 0) { return [pscustomobject]@{ ok=$false; code='TASK_INTENT_FULFILLMENT_REQUIREMENTS_MISSING'; required=$true; record=$null; missing=@('intent requirements') } }
  $propertyByCategory = @{
    integration_obligation = 'integrationObligations'
    preserved_capability = 'preservedCapabilities'
    acceptance_criterion = 'acceptanceCriteria'
  }
  $submitted = @{}
  $issues = @()
  foreach ($category in @($propertyByCategory.Keys | Sort-Object)) {
    $propertyName = [string]$propertyByCategory[$category]
    $property = $candidate.PSObject.Properties[$propertyName]
    foreach ($item in @(if($property){@($property.Value)}else{@()})) {
      if (-not $item) { continue }
      $requirement = Normalize-SuperBrainIntentFulfillmentText $item.requirement 240
      $requirementHash = Normalize-SuperBrainIntentFulfillmentText $item.requirementHash 64
      if ([string]::IsNullOrWhiteSpace($requirementHash) -and -not [string]::IsNullOrWhiteSpace($requirement)) {
        $requirementHash = Get-SuperBrainStableHash ($category + '|' + $requirement.ToLowerInvariant()) 64
      }
      if ([string]::IsNullOrWhiteSpace($requirementHash) -or $submitted.ContainsKey($requirementHash)) { $issues += ($propertyName + ':duplicate_or_missing_requirement'); continue }
      $evidenceRefs = @()
      if ($item.PSObject.Properties['evidenceRefs']) {
        $evidenceRefs = @($item.evidenceRefs | ForEach-Object { Normalize-SuperBrainIntentFulfillmentText $_ 300 } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique -First 12)
      }
      $submitted[$requirementHash] = [pscustomobject]@{ category=$category; requirement=$requirement; requirementHash=$requirementHash; ok=($item.PSObject.Properties['ok'] -and $item.ok -eq $true); evidenceRefs=@($evidenceRefs) }
    }
  }

  $items = @()
  foreach ($requirement in @($requirements)) {
    $match = if($submitted.ContainsKey([string]$requirement.requirementHash)){$submitted[[string]$requirement.requirementHash]}else{$null}
    $itemOk = ($match -and [string]$match.category -eq [string]$requirement.category -and $match.ok -eq $true -and @($match.evidenceRefs).Count -gt 0)
    if (-not $itemOk) { $issues += ([string]$requirement.category + ':' + [string]$requirement.requirement) }
    $items += [pscustomobject][ordered]@{
      category=[string]$requirement.category;ordinal=[int]$requirement.ordinal;requirement=[string]$requirement.requirement
      requirementHash=[string]$requirement.requirementHash;ok=[bool]$itemOk;evidenceRefs=@(if($match){@($match.evidenceRefs)}else{@()})
    }
  }
  if ($submitted.Count -ne $requirements.Count) { $issues += 'unexpected_or_missing_requirement_count' }
  $receipt = $Contract.intentResolutionReceipt
  $planReceipt = $Contract.planReceipt
  $record = [pscustomobject][ordered]@{
    schema='super-brain.intent-fulfillment.v1';required=$true;ok=($issues.Count -eq 0)
    taskId=[string]$Contract.taskId;taskInstanceId=[string]$Contract.taskInstanceId;workspaceKey=[string]$Contract.workspaceKey;ownerSessionKey=[string]$Contract.ownerSessionKey
    packageVersion=[string]$Contract.packageVersion;contractRevision=[int]$Contract.revision;intentRevision=[int]$Contract.intentRevision;planFingerprint=[string]$planReceipt.planFingerprint
    intentContractFingerprint=[string]$receipt.intentContractFingerprint;intentReceiptId=[string]$receipt.receiptId;intentReceiptPayloadHash=[string]$receipt.payloadHash
    requirementsFingerprint=Get-SuperBrainIntentRequirementsFingerprint $requirements;items=@($items);missing=@($issues | Select-Object -Unique)
    fulfillmentFingerprint='';rawPromptStored=$false;rawTranscriptStored=$false
  }
  $record.fulfillmentFingerprint = Get-SuperBrainStableHash ((Get-SuperBrainIntentFulfillmentPayload $record) | ConvertTo-Json -Depth 10 -Compress) 64
  return [pscustomobject]@{ ok=[bool]$record.ok; code=if($record.ok){'TASK_INTENT_FULFILLMENT_CURRENT'}else{'TASK_INTENT_FULFILLMENT_UNSATISFIED'}; required=$true; record=$record; missing=@($record.missing) }
}

function Test-SuperBrainIntentFulfillment([object]$Contract,[object]$Record) {
  $required = Test-IntentResolutionReceiptRequired $Contract
  if (-not $required) { return [pscustomobject]@{ ok=$true; required=$false; code='TASK_INTENT_FULFILLMENT_NOT_REQUIRED'; fingerprint=''; missing=@() } }
  if (-not $Record -or [string]$Record.schema -ne 'super-brain.intent-fulfillment.v1') { return [pscustomobject]@{ ok=$false; required=$true; code='TASK_INTENT_FULFILLMENT_REQUIRED'; fingerprint=''; missing=@('intentFulfillment') } }
  $requirements = @(Get-SuperBrainIntentRequirements $Contract)
  $receipt = $Contract.intentResolutionReceipt
  $planReceipt = $Contract.planReceipt
  $issues = @()
  $bindings = [ordered]@{
    taskId=@([string]$Record.taskId,[string]$Contract.taskId);taskInstanceId=@([string]$Record.taskInstanceId,[string]$Contract.taskInstanceId)
    workspaceKey=@([string]$Record.workspaceKey,[string]$Contract.workspaceKey);ownerSessionKey=@([string]$Record.ownerSessionKey,[string]$Contract.ownerSessionKey)
    packageVersion=@([string]$Record.packageVersion,[string]$Contract.packageVersion);contractRevision=@([int]$Record.contractRevision,[int]$Contract.revision)
    intentRevision=@([int]$Record.intentRevision,[int]$Contract.intentRevision);planFingerprint=@([string]$Record.planFingerprint,[string]$planReceipt.planFingerprint)
    intentContractFingerprint=@([string]$Record.intentContractFingerprint,[string]$receipt.intentContractFingerprint);intentReceiptId=@([string]$Record.intentReceiptId,[string]$receipt.receiptId)
    intentReceiptPayloadHash=@([string]$Record.intentReceiptPayloadHash,[string]$receipt.payloadHash)
    requirementsFingerprint=@([string]$Record.requirementsFingerprint,(Get-SuperBrainIntentRequirementsFingerprint $requirements))
  }
  foreach ($name in @($bindings.Keys)) { if ([string]$bindings[$name][0] -ne [string]$bindings[$name][1]) { $issues += $name } }
  $items = @($Record.items)
  if ($items.Count -ne $requirements.Count) { $issues += 'requirementCount' }
  foreach ($requirement in @($requirements)) {
    $matches = @($items | Where-Object { [string]$_.requirementHash -eq [string]$requirement.requirementHash })
    if ($matches.Count -ne 1) { $issues += ([string]$requirement.category + ':missing'); continue }
    $item = $matches[0]
    if ([string]$item.category -ne [string]$requirement.category -or [int]$item.ordinal -ne [int]$requirement.ordinal -or [string]$item.requirement -ne [string]$requirement.requirement -or $item.ok -ne $true -or @($item.evidenceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
      $issues += ([string]$requirement.category + ':' + [string]$requirement.requirement)
    }
  }
  $calculated = Get-SuperBrainStableHash ((Get-SuperBrainIntentFulfillmentPayload $Record) | ConvertTo-Json -Depth 10 -Compress) 64
  if ([string]$Record.fulfillmentFingerprint -ne $calculated) { $issues += 'fulfillmentFingerprint' }
  if ($Record.required -ne $true -or $Record.ok -ne $true) { $issues += 'fulfillmentStatus' }
  return [pscustomobject]@{ ok=($issues.Count -eq 0); required=$true; code=if($issues.Count -eq 0){'TASK_INTENT_FULFILLMENT_CURRENT'}else{'TASK_INTENT_FULFILLMENT_STALE_OR_UNSATISFIED'}; fingerprint=if($issues.Count -eq 0){$calculated}else{''}; missing=@($issues | Select-Object -Unique); requirementCount=$requirements.Count }
}
