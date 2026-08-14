$Root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'scripts\common.ps1')
. (Join-Path $Root 'scripts\internal\user-adaptation-core.ps1')
. (Join-Path $PSScriptRoot 'UserAdaptationConfirmationReceipt.Fixture.ps1')

Describe 'User adaptation confirmation receipt' {
  BeforeEach {
    $script:Workspace=Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $script:Workspace|Out-Null
  }

  It 'roundtrips a content-addressed scoped choice without raw user text' {
    (Get-Command New-UserAdaptationConfirmationReceipt -ErrorAction SilentlyContinue)|Should BeNullOrEmpty
    $receipt=New-TestUserAdaptationConfirmationReceiptFixture -Root $Root -WorkspaceRoot $script:Workspace -TaskId 'task-receipt-roundtrip' -TaskInstanceId 'ti-11111111111111111111111111111111' -WorkspaceKey 'ws-111111111111111111111111' -OwnerSessionKey 'sid-1111111111111111' -ContractRevision 3 -PlanFingerprint ('1'*16) -PlanId 'plan-receipt' -PlanGeneration 1 -PlanOriginFingerprint ('2'*16) -CanonicalFingerprint ('3'*16) -Context review -Scope workflow -WorkflowKey code-review -Signals @([pscustomobject]@{habitKey='reasoning_style';value='evidence_first'}) -ProtocolBinding ([pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural';contexts=[string[]]@('coding','review')}) -InstructionSha256 ('a'*64)
    $validated=Get-UserAdaptationConfirmationReceipt -Root $Root -WorkspaceRoot $script:Workspace -ReceiptPath $receipt.relativePath -ExpectedSha256 $receipt.sha256 -TaskId 'task-receipt-roundtrip' -WorkspaceKey 'ws-111111111111111111111111'
    $validated.ok|Should Be $true
    $validated.workflowKey|Should Be 'code-review'
    $validated.signals[0].habitKey|Should Be 'reasoning_style'
    $validated.protocolBinding.forwardPasses|Should Be 3
    $validated.protocolBinding.riskFloor|Should Be 'structural'
    $validated.record.taskInstanceId|Should Be 'ti-11111111111111111111111111111111'
    $validated.record.planBinding.originFingerprint|Should Be ('2'*16)
    @($validated.protocolBinding.contexts)|Should Be @('coding','review')
    (Get-SuperBrainFileSha256 $receipt.path)|Should Be $receipt.sha256
    (Get-Content -LiteralPath $receipt.path -Raw -Encoding UTF8).Contains('RAW-USER-TEXT-MUST-NOT-APPEAR')|Should Be $false
    (Test-Path -LiteralPath ($receipt.path+'.lock'))|Should Be $false
  }

  It 'rejects cross-task cross-workspace and tampered receipt replay' {
    $receipt=New-TestUserAdaptationConfirmationReceiptFixture -Root $Root -WorkspaceRoot $script:Workspace -TaskId 'task-bound-a' -TaskInstanceId 'ti-22222222222222222222222222222222' -WorkspaceKey 'ws-222222222222222222222222' -OwnerSessionKey 'sid-2222222222222222' -ContractRevision 2 -PlanFingerprint ('4'*16) -PlanId 'plan-bound' -PlanGeneration 1 -PlanOriginFingerprint ('5'*16) -CanonicalFingerprint ('6'*16) -Context coding -Scope project -Signals @([pscustomobject]@{habitKey='response_detail';value='concise'}) -InstructionSha256 ('b'*64)
    $crossTask='';try{$null=Get-UserAdaptationConfirmationReceipt -Root $Root -WorkspaceRoot $script:Workspace -ReceiptPath $receipt.path -ExpectedSha256 $receipt.sha256 -TaskId 'task-bound-b' -WorkspaceKey 'ws-222222222222222222222222'}catch{$crossTask=$_.Exception.Message}
    $crossTask|Should Match 'USER_ADAPTATION_CONFIRMATION_RECEIPT_MISMATCH'
    $crossWorkspace='';try{$null=Get-UserAdaptationConfirmationReceipt -Root $Root -WorkspaceRoot $script:Workspace -ReceiptPath $receipt.path -ExpectedSha256 $receipt.sha256 -TaskId 'task-bound-a' -WorkspaceKey 'ws-333333333333333333333333'}catch{$crossWorkspace=$_.Exception.Message}
    $crossWorkspace|Should Match 'USER_ADAPTATION_CONFIRMATION_RECEIPT_INVALID'
    $record=Get-Content -LiteralPath $receipt.path -Raw -Encoding UTF8|ConvertFrom-Json;$record.selection.context='release';[IO.File]::WriteAllText($receipt.path,($record|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $tampered='';try{$null=Get-UserAdaptationConfirmationReceipt -Root $Root -WorkspaceRoot $script:Workspace -ReceiptPath $receipt.path -ExpectedSha256 $receipt.sha256 -TaskId 'task-bound-a' -WorkspaceKey 'ws-222222222222222222222222'}catch{$tampered=$_.Exception.Message}
    $tampered|Should Match 'USER_ADAPTATION_CONFIRMATION_RECEIPT_MISMATCH'
  }

  It 'rejects content-addressed records with conflicting selections or project workflow confusion' {
    $conflictFixture=New-TestUserAdaptationConfirmationReceiptFixture -Root $Root -WorkspaceRoot $script:Workspace -TaskId 'task-conflict' -TaskInstanceId 'ti-33333333333333333333333333333333' -WorkspaceKey 'ws-444444444444444444444444' -OwnerSessionKey 'sid-4444444444444444' -ContractRevision 1 -PlanFingerprint ('7'*16) -PlanId 'plan-conflict' -PlanGeneration 1 -PlanOriginFingerprint ('8'*16) -CanonicalFingerprint ('9'*16) -Context coding -Scope project -Signals @([pscustomobject]@{habitKey='response_detail';value='concise'}) -InstructionSha256 ('c'*64)
    $conflictFixture.record.selection.signals=@([pscustomobject]@{habitKey='response_detail';value='concise';valueKind='enum'},[pscustomobject]@{habitKey='response_detail';value='detailed';valueKind='enum'})
    $conflictFixture.record.selectionHash=Get-SuperBrainStableHash ($conflictFixture.record.selection|ConvertTo-Json -Depth 8 -Compress) 64
    $conflictPublished=Publish-TestUserAdaptationConfirmationRecord -WorkspaceRoot $script:Workspace -TaskId 'task-conflict' -Record $conflictFixture.record
    $conflict='';try{$null=Get-UserAdaptationConfirmationReceipt -Root $Root -WorkspaceRoot $script:Workspace -ReceiptPath $conflictPublished.relativePath -ExpectedSha256 $conflictPublished.sha256 -TaskId 'task-conflict' -WorkspaceKey 'ws-444444444444444444444444'}catch{$conflict=$_.Exception.Message}
    $conflict|Should Match 'USER_ADAPTATION_CONFIRMATION_SIGNAL_SET_INVALID'

    $scopeFixture=New-TestUserAdaptationConfirmationReceiptFixture -Root $Root -WorkspaceRoot $script:Workspace -TaskId 'task-scope' -TaskInstanceId 'ti-44444444444444444444444444444444' -WorkspaceKey 'ws-444444444444444444444444' -OwnerSessionKey 'sid-4444444444444444' -ContractRevision 1 -PlanFingerprint ('a'*16) -PlanId 'plan-scope' -PlanGeneration 1 -PlanOriginFingerprint ('b'*16) -CanonicalFingerprint ('c'*16) -Context coding -Scope workflow -WorkflowKey code-review -Signals @([pscustomobject]@{habitKey='response_detail';value='concise'}) -InstructionSha256 ('d'*64)
    $scopeFixture.record.selection.scope='project'
    $scopeFixture.record.selectionHash=Get-SuperBrainStableHash ($scopeFixture.record.selection|ConvertTo-Json -Depth 8 -Compress) 64
    $scopePublished=Publish-TestUserAdaptationConfirmationRecord -WorkspaceRoot $script:Workspace -TaskId 'task-scope' -Record $scopeFixture.record
    $scopeError='';try{$null=Get-UserAdaptationConfirmationReceipt -Root $Root -WorkspaceRoot $script:Workspace -ReceiptPath $scopePublished.relativePath -ExpectedSha256 $scopePublished.sha256 -TaskId 'task-scope' -WorkspaceKey 'ws-444444444444444444444444'}catch{$scopeError=$_.Exception.Message}
    $scopeError|Should Match 'USER_ADAPTATION_CONFIRMATION_PROJECT_WORKFLOW_FORBIDDEN'
  }

  It 'binds a receipt to one task instance, plan origin, and current canonical fingerprint' {
    $receipt=New-TestUserAdaptationConfirmationReceiptFixture -Root $Root -WorkspaceRoot $script:Workspace -TaskId 'task-instance-bound' -TaskInstanceId 'ti-55555555555555555555555555555555' -WorkspaceKey 'ws-555555555555555555555555' -OwnerSessionKey 'sid-5555555555555555' -ContractRevision 3 -PlanFingerprint ('d'*16) -PlanId 'plan-instance-bound' -PlanGeneration 2 -PlanOriginFingerprint ('e'*16) -CanonicalFingerprint ('f'*16) -Context review -Scope workflow -WorkflowKey code-review -Signals @() -ProtocolBinding ([pscustomobject]@{forwardPasses=3;reversePasses=2;riskFloor='structural'}) -InstructionSha256 ('e'*64)
    $confirmation=Get-UserAdaptationConfirmationReceipt -Root $Root -WorkspaceRoot $script:Workspace -ReceiptPath $receipt.relativePath -ExpectedSha256 $receipt.sha256 -TaskId 'task-instance-bound' -WorkspaceKey 'ws-555555555555555555555555'
    $contract=[pscustomobject]@{ownerSessionKey='sid-5555555555555555';taskInstanceId='ti-55555555555555555555555555555555';revision=5;planReceipt=[pscustomobject]@{planFingerprint=('1'*16)};canonicalPlan=[pscustomobject]@{planId='plan-instance-bound';generation=2;originFingerprint=('e'*16);currentFingerprint=('f'*16)}}
    (Test-UserAdaptationConfirmationContractBinding $confirmation $contract).ok|Should Be $true
    foreach($mutation in @('task_instance','plan_origin','plan_id','plan_generation','canonical_fingerprint','future_revision')){
      $copy=($contract|ConvertTo-Json -Depth 8|ConvertFrom-Json)
      switch($mutation){
        'task_instance'{$copy.taskInstanceId='ti-66666666666666666666666666666666'}
        'plan_origin'{$copy.canonicalPlan.originFingerprint=('a'*16)}
        'plan_id'{$copy.canonicalPlan.planId='plan-other'}
        'plan_generation'{$copy.canonicalPlan.generation=3}
        'canonical_fingerprint'{$copy.canonicalPlan.currentFingerprint=('2'*16)}
        'future_revision'{$copy.revision=2}
      }
      $result=Test-UserAdaptationConfirmationContractBinding $confirmation $copy
      $result.ok|Should Be $false
      @($result.issues).Count|Should Be 1
    }
  }
}
