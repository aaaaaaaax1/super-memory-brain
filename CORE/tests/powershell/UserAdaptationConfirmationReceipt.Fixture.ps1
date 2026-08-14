function Publish-TestUserAdaptationConfirmationRecord {
  param([string]$WorkspaceRoot,[string]$TaskId,$Record)
  $receiptRoot=Join-Path ([IO.Path]::GetFullPath($WorkspaceRoot)) 'runtime-state\user-confirmation-receipts'
  New-Item -ItemType Directory -Force -Path $receiptRoot|Out-Null
  $pending=Join-Path $receiptRoot ('.fixture-'+[guid]::NewGuid().ToString('n')+'.json')
  try{
    Write-JsonUtf8NoBom $pending $Record 12
    $hash=Get-SuperBrainFileSha256 $pending
    $taskToken='r-'+(Get-SuperBrainStableHash $TaskId 16)
    $final=Join-Path $receiptRoot ($taskToken+'--'+$hash+'.json')
    $published=Publish-SuperBrainImmutableFile -SourcePath $pending -DestinationPath $final -ExpectedSha256 $hash -CollisionCode 'TEST_CONFIRMATION_RECEIPT_COLLISION' -SourceMismatchCode 'TEST_CONFIRMATION_RECEIPT_HASH_FAILED'
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    return [pscustomobject]@{path=$final;relativePath=$final.Substring($workspace.Length).TrimStart('\','/')-replace'\\','/';sha256=$hash;record=$Record;replayed=[bool]$published.replayed}
  }finally{if(Test-Path -LiteralPath $pending){Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue}}
}

function New-TestUserAdaptationConfirmationReceiptFixture {
  param(
    [string]$Root,[string]$WorkspaceRoot,[string]$TaskId,[string]$TaskInstanceId='ti-11111111111111111111111111111111',[string]$WorkspaceKey,[string]$OwnerSessionKey,
    [int]$ContractRevision,[string]$PlanFingerprint,[string]$PlanId,[int]$PlanGeneration,[string]$PlanOriginFingerprint,[string]$CanonicalFingerprint,
    [string]$Context='general',[string]$Scope='project',[string]$WorkflowKey='',[object[]]$Signals=@(),$ProtocolBinding=$null,[string]$InstructionSha256,[string]$ObservedAt=''
  )
  $workspaceKeyValue=Get-SuperBrainWorkspaceKey $WorkspaceKey
  $normalizedSignals=@($Signals|ForEach-Object{
    $typed=ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey ([string]$_.habitKey) -Value ([string]$_.value)
    [pscustomobject]@{habitKey=$typed.habitKey;value=$typed.value;valueKind='enum'}
  }|Sort-Object habitKey,value -Unique)
  $normalizedProtocol=$null
  if($ProtocolBinding){
    $normalizedProtocol=[pscustomobject]@{forwardPasses=[int]$ProtocolBinding.forwardPasses;reversePasses=[int]$ProtocolBinding.reversePasses;riskFloor=([string]$ProtocolBinding.riskFloor).ToLowerInvariant()}
    if($ProtocolBinding.PSObject.Properties['contexts']){$normalizedProtocol|Add-Member -NotePropertyName contexts -NotePropertyValue @($ProtocolBinding.contexts|ForEach-Object{([string]$_).ToLowerInvariant()}|Sort-Object -Unique) -Force}
  }
  $workflow=$null
  if($Scope-eq'workflow'){$workflow=[pscustomobject]@{key=$WorkflowKey.ToLowerInvariant();identitySha256=Get-UserAdaptationWorkflowIdentityHash $workspaceKeyValue $WorkflowKey}}
  $selection=[ordered]@{source='accepted_outcome';context=$Context;scope=$Scope;workflow=$workflow;signals=@($normalizedSignals);protocolBinding=$normalizedProtocol}
  $selectionHash=Get-SuperBrainStableHash (([pscustomobject]$selection|ConvertTo-Json -Depth 8 -Compress)) 64
  $instructionHash=$InstructionSha256.ToLowerInvariant()
  $record=[pscustomobject]@{
    schema='super-brain.user-adaptation-confirmation-receipt.v2';producer='codex_host_user_turn';actor='real_user';authorityKind='structured_task_choice';trustLevel='local_same_user_unattested';taskId=$TaskId;taskInstanceId=$TaskInstanceId;workspaceKey=$workspaceKeyValue;ownerSessionKey=$OwnerSessionKey
    userEvent=[pscustomobject]@{eventIdHash=Get-SuperBrainStableHash ("$OwnerSessionKey|$TaskId|$TaskInstanceId|$instructionHash|$ContractRevision") 64;instructionSha256=$instructionHash;observedAt=if([string]::IsNullOrWhiteSpace($ObservedAt)){'2026-07-22T00:00:00Z'}else{$ObservedAt}}
    contractBinding=[pscustomobject]@{acceptedRevision=$ContractRevision;planFingerprint=$PlanFingerprint}
    planBinding=[pscustomobject]@{planId=$PlanId;generation=$PlanGeneration;originFingerprint=$PlanOriginFingerprint;canonicalFingerprint=$CanonicalFingerprint}
    selection=[pscustomobject]$selection;selectionHash=$selectionHash;privacy=[pscustomobject]@{rawPromptStored=$false;rawTranscriptStored=$false};rawPromptStored=$false
  }
  $published=Publish-TestUserAdaptationConfirmationRecord -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -Record $record
  $published|Add-Member -NotePropertyName selectionHash -NotePropertyValue $selectionHash -Force
  return $published
}
