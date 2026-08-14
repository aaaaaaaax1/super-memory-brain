# Composite decision binding adapter. It keeps the legacy registry readable while
# allowing typed SQLite decision cards to participate in the same guarded flow.

function Get-NativeDecisionBindingPath([string]$RequestedPath = '') {
  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) { return [IO.Path]::GetFullPath($RequestedPath) }
  return Get-DecisionBindingReceiptPath $TaskId $StageKind
}

function Get-NativeDecisionBindingLegacyReceiptPath([string]$CompositePath) {
  if ([string]::IsNullOrWhiteSpace($CompositePath)) { return '' }
  $directory = Split-Path -Parent $CompositePath
  $name = [IO.Path]::GetFileNameWithoutExtension($CompositePath)
  if ([string]::IsNullOrWhiteSpace($directory) -or [string]::IsNullOrWhiteSpace($name)) { return '' }
  return Join-Path $directory ($name + '.legacy-v1.json')
}

function Get-NativeDecisionBindingManifestHash {
  $path = Join-Path $Root 'manifest.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'DECISION_BINDING_NATIVE_MANIFEST_MISSING' }
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-NativeDecisionBindingDatabase {
  return Test-Path -LiteralPath (Join-Path $memoryBase 'workspace\brain-state.sqlite3') -PathType Leaf
}

function New-NativeDecisionBindingScope([string]$CommandSeed = '') {
  $scope = [ordered]@{
    taskId = $TaskId
    taskInstanceId = $TaskInstanceId
    workspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
    ownerSessionKey = $OwnerSessionKey
    stageKind = $StageKind
    worklineId = $WorklineId
    intentFingerprint = $IntentFingerprint
    packageVersion = [string]$manifest.version
    packageManifestHash = Get-NativeDecisionBindingManifestHash
    contractRevision = [int]$ContractRevision
    planFingerprint = $PlanFingerprint
    source = 'decision-binding.native-adapter'
  }
  if (-not [string]::IsNullOrWhiteSpace($CommandSeed)) {
    $material = @(
      'native-decision-binding-v1', $CommandSeed, $TaskId, $TaskInstanceId,
      $scope.workspaceKey, $OwnerSessionKey, $StageKind, $PlanFingerprint,
      $WorklineId, $IntentFingerprint, [string]$ContractRevision, [string]$scope.packageManifestHash
    ) -join '|'
    $scope.commandId = 'native-decision-' + (Get-SuperBrainStableHash $material 48)
  }
  return [pscustomobject]$scope
}

function Invoke-NativeDecisionBindingControl([string]$Action,[object]$Request) {
  if (-not (Test-NativeDecisionBindingDatabase)) {
    return [pscustomobject]@{ available=$false; ok=$true; code='DECISION_BINDING_NATIVE_DATABASE_ABSENT'; value=$null }
  }
  $python = Get-Command python -ErrorAction SilentlyContinue
  $runtime = Join-Path $Root 'runtime\brain_control.py'
  if (-not $python -or -not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return [pscustomobject]@{ available=$true; ok=$false; code='DECISION_BINDING_NATIVE_RUNTIME_UNAVAILABLE'; error='Typed decision authority is present but its runtime is unavailable.'; value=$null }
  }
  $pythonPath = [string]$python.Source
  if ([string]::IsNullOrWhiteSpace($pythonPath)) { $pythonPath = [string]$python.Name }
  try {
    $json = $Request | ConvertTo-Json -Depth 20 -Compress
    $raw = @($json | & $pythonPath -X utf8 -B $runtime --state-root $memoryBase $Action 2>&1)
    $exitCode = $LASTEXITCODE
    $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $value = ConvertFrom-SuperBrainJsonOutput $text ('native decision binding ' + $Action)
    if ($exitCode -ne 0 -or -not $value -or $value.ok -ne $true) {
      return [pscustomobject]@{
        available=$true
        ok=$false
        code=if($value -and $value.PSObject.Properties['code']){[string]$value.code}else{'DECISION_BINDING_NATIVE_CONTROL_FAILED'}
        error=if($value -and $value.PSObject.Properties['error']){[string]$value.error}else{$text}
        value=$value
      }
    }
    return [pscustomobject]@{ available=$true; ok=$true; code='DECISION_BINDING_NATIVE_CONTROL_OK'; value=$value }
  } catch {
    return [pscustomobject]@{ available=$true; ok=$false; code='DECISION_BINDING_NATIVE_CONTROL_FAILED'; error=$_.Exception.Message; value=$null }
  }
}

function Resolve-NativeDecisionBinding {
  if (-not (Test-NativeDecisionBindingDatabase)) {
    return [pscustomobject]@{ available=$false; ok=$true; status='none_applicable'; code='DECISION_BINDING_NATIVE_DATABASE_ABSENT'; receiptId=''; bindingDigest=''; decisions=@(); reasons=@() }
  }
  $request = New-NativeDecisionBindingScope 'resolve'
  $control = Invoke-NativeDecisionBindingControl 'resolve-decisions' $request
  if (-not $control.ok) {
    return [pscustomobject]@{ available=$true; ok=$false; status='withheld'; code=[string]$control.code; receiptId=''; bindingDigest=''; decisions=@(); reasons=@([string]$control.error) }
  }
  $value = $control.value
  return [pscustomobject]@{
    available=$true
    ok=($value.ok -eq $true)
    status=[string]$value.status
    code='DECISION_BINDING_NATIVE_RESOLVED'
    receiptId=[string]$value.receiptId
    bindingDigest=[string]$value.bindingDigest
    decisions=@($value.decisions)
    reasons=@($value.reasons)
  }
}

function Test-NativeDecisionBindingReceipt([object]$Stored) {
  if (-not $Stored -or $Stored.available -ne $true) {
    return [pscustomobject]@{ available=$false; ok=$true; status='none_applicable'; code='DECISION_BINDING_NATIVE_DATABASE_ABSENT'; receiptId=''; bindingDigest=''; decisions=@(); reasons=@() }
  }
  $request = New-NativeDecisionBindingScope
  $request | Add-Member -NotePropertyName receiptId -NotePropertyValue ([string]$Stored.receiptId) -Force
  $request | Add-Member -NotePropertyName bindingDigest -NotePropertyValue ([string]$Stored.bindingDigest) -Force
  $control = Invoke-NativeDecisionBindingControl 'check-decision-resolution' $request
  if (-not $control.ok) {
    return [pscustomobject]@{ available=$true; ok=$false; status='withheld'; code=[string]$control.code; receiptId=[string]$Stored.receiptId; bindingDigest=[string]$Stored.bindingDigest; decisions=@(); reasons=@([string]$control.error) }
  }
  $value = $control.value
  return [pscustomobject]@{
    available=$true
    ok=($value.ok -eq $true)
    status=[string]$value.status
    code='DECISION_BINDING_NATIVE_RECEIPT_CURRENT'
    receiptId=[string]$value.receiptId
    bindingDigest=[string]$value.bindingDigest
    decisions=@($value.decisions)
    reasons=@($value.reasons)
  }
}

function Copy-NativeDecisionBindingLegacyReceipt([object]$Legacy) {
  $source = [string]$Legacy.path
  $target = Get-NativeDecisionBindingLegacyReceiptPath (Get-NativeDecisionBindingPath)
  if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Leaf) -or [string]::IsNullOrWhiteSpace($target)) {
    throw 'DECISION_BINDING_LEGACY_RECEIPT_COPY_FAILED'
  }
  $directory = Split-Path -Parent $target
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $temporary = $target + '.pending-' + [guid]::NewGuid().ToString('n').Substring(0,8)
  try {
    [IO.File]::WriteAllBytes($temporary, [IO.File]::ReadAllBytes($source))
    Move-Item -LiteralPath $temporary -Destination $target -Force
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
  }
  return $target
}

function ConvertTo-NativeDecisionBindingViews([object]$Legacy,[object]$Native) {
  $views = @()
  foreach ($decision in @($Legacy.decisions)) {
    $views += [pscustomobject]@{
      source='legacy'
      decisionId=[string]$decision.decisionId
      nativeCardId=''
      revision=[int]$decision.revision
      contentHash=[string]$decision.contentHash
      enforcement=[string]$decision.enforcement
      completionCriteriaDigest=[string]$decision.completionCriteriaDigest
      recordFingerprint=[string]$decision.recordFingerprint
    }
  }
  foreach ($decision in @($Native.decisions)) {
    $views += [pscustomobject]@{
      source='native'
      decisionId=('native:' + [string]$decision.cardId)
      nativeCardId=[string]$decision.cardId
      revision=[int]$decision.cardRevision
      contentHash=[string]$decision.contentHash
      enforcement=[string]$decision.enforcement
      completionCriteriaDigest=[string]$decision.completionCriteriaDigest
      recordFingerprint=''
    }
  }
  $deduplicated = @{}
  foreach ($view in @($views | Sort-Object source,decisionId,revision)) {
    $key = @([string]$view.enforcement,[string]$view.contentHash,[string]$view.completionCriteriaDigest) -join '|'
    if (-not $deduplicated.ContainsKey($key) -or ([string]$view.source -eq 'native' -and [string]$deduplicated[$key].source -eq 'legacy')) {
      $deduplicated[$key] = $view
    }
  }
  return @($deduplicated.Values | Sort-Object source,decisionId,revision)
}

function New-NativeDecisionBindingCompositeReceipt([object]$Legacy,[object]$Native,[string]$LegacyPath='') {
  $views = @(ConvertTo-NativeDecisionBindingViews $Legacy $Native)
  $reasons = @($Legacy.reasons + $Native.reasons | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique -First 8)
  $withheld = ($Legacy.ok -ne $true) -or ($Native.available -eq $true -and $Native.ok -ne $true)
  $gates = @($views | Where-Object { [string]$_.enforcement -eq 'completion_gate' })
  if ($gates.Count -gt 1) {
    $withheld = $true
    $reasons = @($reasons + @('overlapping_completion_gate_decisions') | Select-Object -Unique -First 8)
  }
  $status = if ($withheld) { 'withheld' } elseif (@($views).Count -gt 0) { 'bound' } else { 'none_applicable' }
  $legacySummary = [ordered]@{
    available=$true
    status=[string]$Legacy.status
    bindingDigest=[string]$Legacy.bindingDigest
    path=$LegacyPath
    decisionCount=@($Legacy.decisions).Count
  }
  $nativeSummary = [ordered]@{
    available=[bool]$Native.available
    status=[string]$Native.status
    receiptId=[string]$Native.receiptId
    bindingDigest=[string]$Native.bindingDigest
    decisionCount=@($Native.decisions).Count
  }
  $material = [ordered]@{
    taskId=$TaskId
    taskInstanceId=$TaskInstanceId
    workspaceKey=Get-SuperBrainWorkspaceKey $WorkspaceKey
    worklineId=$WorklineId
    stageKind=$StageKind
    intentFingerprint=$IntentFingerprint
    ownerSessionKey=$OwnerSessionKey
    contractRevision=[int]$ContractRevision
    planFingerprint=$PlanFingerprint
    packageVersion=[string]$manifest.version
    packageManifestHash=Get-NativeDecisionBindingManifestHash
    status=$status
    legacy=$legacySummary
    native=$nativeSummary
    decisions=@($views | ForEach-Object {
      [ordered]@{
        source=[string]$_.source
        decisionId=[string]$_.decisionId
        nativeCardId=[string]$_.nativeCardId
        revision=[int]$_.revision
        contentHash=[string]$_.contentHash
        enforcement=[string]$_.enforcement
        completionCriteriaDigest=[string]$_.completionCriteriaDigest
        recordFingerprint=[string]$_.recordFingerprint
      }
    })
    reasons=@($reasons)
  }
  $digest = Get-SuperBrainStableHash ($material | ConvertTo-Json -Depth 16 -Compress) 64
  return [pscustomobject]@{
    ok=($status -ne 'withheld')
    schema='super-brain.decision-resolution-receipt.v2'
    receiptId='decision-composite-' + $digest.Substring(0,16)
    taskId=$TaskId
    taskInstanceId=$TaskInstanceId
    workspaceKey=Get-SuperBrainWorkspaceKey $WorkspaceKey
    worklineId=$WorklineId
    stageKind=$StageKind
    intentFingerprint=$IntentFingerprint
    ownerSessionKey=$OwnerSessionKey
    contractRevision=[int]$ContractRevision
    planFingerprint=$PlanFingerprint
    packageVersion=[string]$manifest.version
    packageManifestHash=[string]$material.packageManifestHash
    status=$status
    bindingDigest=$digest
    legacy=[pscustomobject]$legacySummary
    native=[pscustomobject]$nativeSummary
    decisions=@($views)
    reasons=@($reasons)
    createdAt=(Get-Date).ToString('o')
    path=''
    rawDecisionBodyStored=$false
    rawPromptStored=$false
  }
}

function Get-DecisionBindingReceipt([string]$RequestedPath = '') {
  $path = Get-NativeDecisionBindingPath $RequestedPath
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RECEIPT_MISSING'; path=$path }
  }
  $receipt = Read-DecisionBindingJson $path
  if (-not $receipt -or [string]$receipt.schema -notin @('super-brain.decision-resolution-receipt.v1','super-brain.decision-resolution-receipt.v2')) {
    return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RECEIPT_INVALID'; path=$path }
  }
  $receipt | Add-Member -NotePropertyName path -NotePropertyValue $path -Force
  return $receipt
}

function Invoke-NativeLegacyDecisionBinding([scriptblock]$Operation,[string]$LegacyPath,[string]$LegacyDigest='') {
  return & {
    param($LegacyOperation,$ScopedReceiptPath,$ScopedDigest)
    $ReceiptPath = $ScopedReceiptPath
    if (-not [string]::IsNullOrWhiteSpace($ScopedDigest)) { $BindingDigest = $ScopedDigest }
    & $LegacyOperation
  } $Operation $LegacyPath $LegacyDigest
}

function Test-NativeDecisionBindingCompositeScope([object]$Receipt) {
  foreach ($pair in @(
    @('taskId',$TaskId), @('taskInstanceId',$TaskInstanceId), @('workspaceKey',(Get-SuperBrainWorkspaceKey $WorkspaceKey)),
    @('worklineId',$WorklineId), @('stageKind',$StageKind), @('intentFingerprint',$IntentFingerprint),
    @('ownerSessionKey',$OwnerSessionKey), @('planFingerprint',$PlanFingerprint)
  )) {
    if ([string]$Receipt.$($pair[0]) -ne [string]$pair[1]) { return 'DECISION_BINDING_RECEIPT_' + $pair[0].ToUpperInvariant() + '_MISMATCH' }
  }
  if ([int]$Receipt.contractRevision -ne [int]$ContractRevision -or [string]$Receipt.packageVersion -ne [string]$manifest.version) {
    return 'DECISION_BINDING_RECEIPT_VERSION_OR_REVISION_MISMATCH'
  }
  if ([string]$Receipt.packageManifestHash -ne (Get-NativeDecisionBindingManifestHash)) {
    return 'DECISION_BINDING_RECEIPT_PACKAGE_MANIFEST_HASH_MISMATCH'
  }
  return ''
}

function Resolve-DecisionBinding {
  Assert-DecisionBindingResolutionInput
  $legacy = & $script:LegacyResolveDecisionBinding
  if (-not $legacy -or -not $legacy.PSObject.Properties['path']) { throw 'DECISION_BINDING_LEGACY_RESOLUTION_INVALID' }
  $legacyPath = Copy-NativeDecisionBindingLegacyReceipt $legacy
  $legacy | Add-Member -NotePropertyName path -NotePropertyValue $legacyPath -Force
  $native = Resolve-NativeDecisionBinding
  $receipt = New-NativeDecisionBindingCompositeReceipt $legacy $native $legacyPath
  $receipt.path = Get-NativeDecisionBindingPath
  Write-DecisionBindingJson $receipt.path $receipt 16
  return $receipt
}

function Validate-DecisionBindingReceipt {
  Assert-DecisionBindingResolutionInput
  $receipt = Get-DecisionBindingReceipt $ReceiptPath
  if ($receipt.ok -ne $true -and [string]$receipt.code) { return $receipt }
  if ([string]$receipt.schema -eq 'super-brain.decision-resolution-receipt.v1') {
    return & $script:LegacyValidateDecisionBindingReceipt
  }
  $scopeCode = Test-NativeDecisionBindingCompositeScope $receipt
  if (-not [string]::IsNullOrWhiteSpace($scopeCode)) { return [pscustomobject]@{ ok=$false; status='withheld'; code=$scopeCode; path=$receipt.path } }
  $legacy = Invoke-NativeLegacyDecisionBinding $script:LegacyValidateDecisionBindingReceipt ([string]$receipt.legacy.path)
  if (-not $legacy) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_LEGACY_RECEIPT_INVALID'; path=$receipt.path } }
  $legacyCurrent = [pscustomobject]@{
    ok=($legacy.ok -eq $true); status=[string]$legacy.status; bindingDigest=[string]$legacy.bindingDigest; path=[string]$receipt.legacy.path; decisions=@($legacy.decisions); reasons=@($legacy.reasons)
  }
  $native = Test-NativeDecisionBindingReceipt $receipt.native
  $current = New-NativeDecisionBindingCompositeReceipt $legacyCurrent $native ([string]$receipt.legacy.path)
  if ([string]$current.bindingDigest -ne [string]$receipt.bindingDigest -or [string]$current.status -ne [string]$receipt.status) {
    return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RECEIPT_STALE_OR_FOREIGN'; path=$receipt.path; reasons=@($current.reasons) }
  }
  $current.path = $receipt.path
  return [pscustomobject]@{
    ok=($current.ok -eq $true)
    status=[string]$current.status
    code=if($current.ok){'DECISION_BINDING_RECEIPT_CURRENT'}else{'DECISION_BINDING_RECEIPT_WITHHELD'}
    receiptId=[string]$current.receiptId
    bindingDigest=[string]$current.bindingDigest
    packageManifestHash=[string]$current.packageManifestHash
    decisions=@($current.decisions)
    path=$current.path
    legacy=$current.legacy
    native=$current.native
    reasons=@($current.reasons)
    rawDecisionBodyStored=$false
  }
}

function Get-DecisionBindingPrivateGuidance {
  $receipt = Get-DecisionBindingReceipt $ReceiptPath
  if ($receipt.ok -ne $true -and [string]$receipt.code) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_GUIDANCE_RECEIPT_INVALID'; guidance=@(); rawPromptStored=$false } }
  if ([string]$receipt.schema -eq 'super-brain.decision-resolution-receipt.v1') {
    return Invoke-NativeLegacyDecisionBinding $script:LegacyGetDecisionBindingPrivateGuidance ([string]$receipt.path)
  }
  $validated = Validate-DecisionBindingReceipt
  if ($validated.ok -ne $true) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_GUIDANCE_RECEIPT_INVALID'; guidance=@(); reasons=@($validated.reasons); rawPromptStored=$false } }
  if ([string]$validated.status -eq 'none_applicable') { return [pscustomobject]@{ ok=$true; status='none_applicable'; code='DECISION_BINDING_GUIDANCE_NONE_APPLICABLE'; guidance=@(); rawPromptStored=$false } }
  $guidance = @()
  if ([string]$validated.legacy.status -eq 'bound') {
    $legacyGuidance = Invoke-NativeLegacyDecisionBinding $script:LegacyGetDecisionBindingPrivateGuidance ([string]$validated.legacy.path)
    if (-not $legacyGuidance -or $legacyGuidance.ok -ne $true) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_LEGACY_GUIDANCE_INVALID'; guidance=@(); rawPromptStored=$false } }
    $guidance += @($legacyGuidance.guidance)
  }
  if ($validated.native.available -eq $true -and [string]$validated.native.status -eq 'bound') {
    $request = New-NativeDecisionBindingScope
    $request | Add-Member -NotePropertyName receiptId -NotePropertyValue ([string]$validated.native.receiptId) -Force
    $request | Add-Member -NotePropertyName bindingDigest -NotePropertyValue ([string]$validated.native.bindingDigest) -Force
    $control = Invoke-NativeDecisionBindingControl 'get-decision-context' $request
    if (-not $control.ok -or -not $control.value -or $control.value.ok -ne $true) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_NATIVE_GUIDANCE_INVALID'; guidance=@(); rawPromptStored=$false } }
    foreach ($constraint in @($control.value.constraints)) {
      $parts = @([string]$constraint.summary)
      if (@($constraint.consequences).Count -gt 0) { $parts += ('Consequences: ' + (@($constraint.consequences) -join '; ')) }
      if (@($constraint.completionCriteria).Count -gt 0) { $parts += ('Completion: ' + (@($constraint.completionCriteria) -join '; ')) }
      $text = Limit-DecisionBindingText ($parts -join ' ') 720
      $guidance += [pscustomobject]@{
        decisionId=('native:' + [string]$constraint.cardId)
        revision=[int]$constraint.cardRevision
        text=$text
        guidanceHash=Get-SuperBrainStableHash $text 64
      }
    }
  }
  return [pscustomobject]@{ ok=$true; status='bound'; code='DECISION_BINDING_GUIDANCE_READY'; bindingDigest=[string]$validated.bindingDigest; guidance=@($guidance); rawPromptStored=$false; rawDecisionBodyPersistedInReceipt=$false }
}

function Record-DecisionBindingResult {
  if ([string]::IsNullOrWhiteSpace($DecisionId) -or $Revision -lt 1 -or [string]::IsNullOrWhiteSpace($BindingDigest)) { throw 'DECISION_BINDING_RESULT_IDENTITY_REQUIRED' }
  $receipt = Get-DecisionBindingReceipt $ReceiptPath
  if ([string]$receipt.schema -eq 'super-brain.decision-resolution-receipt.v1') {
    return Invoke-NativeLegacyDecisionBinding $script:LegacyRecordDecisionBindingResult ([string]$receipt.path) $BindingDigest
  }
  $validated = Validate-DecisionBindingReceipt
  if ($validated.ok -ne $true -or [string]$validated.status -ne 'bound' -or [string]$BindingDigest -ne [string]$validated.bindingDigest) {
    return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RESULT_RECEIPT_NOT_CURRENT' }
  }
  $decision = @($validated.decisions | Where-Object { [string]$_.decisionId -eq [string]$DecisionId -and [int]$_.revision -eq $Revision } | Select-Object -First 1)
  if ($decision.Count -ne 1) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RESULT_FOREIGN_OR_STALE' } }
  if ([string]$decision[0].source -eq 'legacy') {
    return Invoke-NativeLegacyDecisionBinding $script:LegacyRecordDecisionBindingResult ([string]$validated.legacy.path) ([string]$validated.legacy.bindingDigest)
  }
  $seed = @('record',[string]$validated.native.receiptId,[string]$decision[0].nativeCardId,[string]$decision[0].revision,[string][bool]$ResultOk,@($EvidenceRefs | Sort-Object) -join ',') -join '|'
  $request = New-NativeDecisionBindingScope $seed
  $request | Add-Member -NotePropertyName receiptId -NotePropertyValue ([string]$validated.native.receiptId) -Force
  $request | Add-Member -NotePropertyName bindingDigest -NotePropertyValue ([string]$validated.native.bindingDigest) -Force
  $request | Add-Member -NotePropertyName cardId -NotePropertyValue ([string]$decision[0].nativeCardId) -Force
  $request | Add-Member -NotePropertyName cardRevision -NotePropertyValue ([int]$decision[0].revision) -Force
  $request | Add-Member -NotePropertyName resultOk -NotePropertyValue ([bool]$ResultOk) -Force
  $request | Add-Member -NotePropertyName evidenceRefs -NotePropertyValue @($EvidenceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique -First 12) -Force
  $control = Invoke-NativeDecisionBindingControl 'record-decision-result' $request
  if (-not $control.ok) { return [pscustomobject]@{ ok=$false; status='withheld'; code=[string]$control.code; error=[string]$control.error } }
  return [pscustomobject]@{ ok=$true; status='recorded'; bindingDigest=[string]$validated.bindingDigest; decisionId=[string]$decision[0].decisionId; revision=[int]$decision[0].revision; source='native'; resultId=[string]$control.value.resultId; idempotent=[bool]$control.value.idempotent }
}

function Validate-DecisionBindingCompletion {
  $receipt = Get-DecisionBindingReceipt $ReceiptPath
  if ([string]$receipt.schema -eq 'super-brain.decision-resolution-receipt.v1') {
    return Invoke-NativeLegacyDecisionBinding $script:LegacyValidateDecisionBindingCompletion ([string]$receipt.path)
  }
  $validated = Validate-DecisionBindingReceipt
  if ($validated.ok -ne $true) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_COMPLETION_RECEIPT_INVALID'; receipt=$validated } }
  if ([string]$validated.status -eq 'none_applicable') { return [pscustomobject]@{ ok=$true; status='none_applicable'; code='DECISION_BINDING_COMPLETION_NONE_APPLICABLE'; bindingDigest=[string]$validated.bindingDigest; decisionCount=0; results=@() } }
  $results = @()
  if (@($validated.decisions | Where-Object { [string]$_.source -eq 'legacy' -and [string]$_.enforcement -eq 'completion_gate' }).Count -gt 0) {
    $legacy = Invoke-NativeLegacyDecisionBinding $script:LegacyValidateDecisionBindingCompletion ([string]$validated.legacy.path)
    if (-not $legacy -or $legacy.ok -ne $true) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_COMPLETION_RESULTS_UNSATISFIED'; bindingDigest=[string]$validated.bindingDigest; legacy=$legacy; failures=if($legacy -and $legacy.PSObject.Properties['failures']){@($legacy.failures)}else{@('legacy_completion_result_missing_or_invalid')} } }
    $results += @($legacy.results | ForEach-Object { $_ | Add-Member -NotePropertyName source -NotePropertyValue 'legacy' -Force; $_ })
  }
  if (@($validated.decisions | Where-Object { [string]$_.source -eq 'native' -and [string]$_.enforcement -eq 'completion_gate' }).Count -gt 0) {
    $request = New-NativeDecisionBindingScope
    $request | Add-Member -NotePropertyName receiptId -NotePropertyValue ([string]$validated.native.receiptId) -Force
    $request | Add-Member -NotePropertyName bindingDigest -NotePropertyValue ([string]$validated.native.bindingDigest) -Force
    $control = Invoke-NativeDecisionBindingControl 'validate-decision-completion' $request
    if (-not $control.ok -or $control.value.completionCurrent -ne $true) { return [pscustomobject]@{ ok=$false; status='withheld'; code=if($control.ok){[string]$control.value.code}else{[string]$control.code}; bindingDigest=[string]$validated.bindingDigest; native=$control.value } }
    $results += @($control.value.results | ForEach-Object { [pscustomobject]@{ source='native'; decisionId=('native:' + [string]$_.cardId); revision=[int]$_.cardRevision; resultId=[string]$_.resultId } })
  }
  return [pscustomobject]@{ ok=$true; status='bound'; code='DECISION_BINDING_COMPLETION_RESULTS_CURRENT'; bindingDigest=[string]$validated.bindingDigest; decisionCount=@($validated.decisions).Count; results=@($results) }
}
