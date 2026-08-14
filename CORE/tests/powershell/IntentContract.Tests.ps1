$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$preflightScript = Join-Path $root 'scripts\cognitive-preflight.ps1'
$enforceScript = Join-Path $root 'scripts\cognitive-enforce.ps1'

function Invoke-IntentContract([object[]]$Arguments) {
  $parameters = @{}
  $switches = @('RequireIntentContract','RequireStructuralGuards','RebindSession','RetainForMerge','EnableCanonicalPlan','RequiresReconciliation')
  for ($index = 0; $index -lt $Arguments.Count; ) {
    $rawName = [string]$Arguments[$index]
    if (-not $rawName.StartsWith('-')) { throw "expected parameter name, got $rawName" }
    $name = $rawName.TrimStart('-')
    if ($switches -contains $name) {
      $parameters[$name] = $true
      $index++
      continue
    }
    if (($index + 1) -ge $Arguments.Count) { throw "missing value for $rawName" }
    $parameters[$name] = $Arguments[$index + 1]
    $index += 2
  }
  $parameters.NoExit = $true
  $parameters.Json = $true
  $raw = @(& $contractScript @parameters 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'execution contract returned no JSON' }
  return ($text | ConvertFrom-Json)
}

function New-TestIntentJson([string[]]$MaterialUnknowns = @()) {
  return ([pscustomobject]@{
    schema = 'super-brain.intent-contract.v2'
    literalRequestDigest = 'editable notebook, but no direct database writes'
    resolvedOutcome = 'Users can edit notebook entries through governed commands.'
    productRole = 'local notebook UI backed by a governed command API'
    integrationObligations = @('local UI','governed command API','task receipt')
    materialUnknowns = @($MaterialUnknowns)
    compatibilityGuards = @('no browser-side direct SQLite or database writes')
    preservedCapabilities = @('editable notebook')
    acceptanceCriteria = @('an edit produces a receipt')
    governedEquivalent = 'governed command editing through a local API'
    autonomyTier = 'align'
    integrationMap = [pscustomobject]@{
      entryPoint='notebook page';userFlow='open note, edit, save, observe receipt';domainOwner='BrainControl command engine';stateOwner='brain-state SQLite authority'
      downstreamConsumers=@('notebook query projection','history view');failureRecovery='CAS conflict keeps the draft and offers retry';privacyPerformance='loopback only and bounded payloads'
      compatibilityMigration='legacy records remain read-only until migration';verification='command API and real user edit-flow regression';completionCondition='edit, history, and rollback path are verified'
    }
    investigationEvidence = @('runtime/brain_control.py command authority','approved P-1 plan')
    materialBranches = @()
    focusedQuestion = ''
    preserveExistingFlow = $true
    replacementReceipt = ''
    componentResolution = [pscustomobject]@{requestedComponent='direct database editor';resolvedComponent='governed command API';outcomePreserved=$true;reason='the command API preserves editing with receipts and rollback'}
  } | ConvertTo-Json -Compress)
}

function Write-IntentTestJson([string]$Path,[object]$Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
}

Describe 'Task-scoped intent resolution receipt' {
  It 'binds a governed editable capability to the current task and authorizes guarded work' {
    $stateRoot = Join-Path $TestDrive 'intent-current'
    $workspaceKey = 'ws-i11111111111111111111111'
    $sessionKey = 'sid-i11111111111111111111111'
    $taskId = 'task-intent-current'
    $created = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','notebook-ui','-NextAction','implement governed notebook editing','-LatestUserInstruction','add editable notebook without direct database writes','-IntentContractJson',(New-TestIntentJson),'-StateRoot',$stateRoot)
    $guard = Invoke-IntentContract -Arguments @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ProposedWorkId','notebook-ui','-ExpectedRevision',([string]$created.revision),'-ExpectedPlanFingerprint',([string]$created.planReceipt.planFingerprint),'-RequireIntentContract','-StateRoot',$stateRoot)

    $created.ok | Should Be $true
    $created.intentContractRequired | Should Be $true
    $created.intentContract.productRole | Should Match 'governed command API'
    $created.intentContract.componentResolution.requestedComponent | Should Be 'direct database editor'
    $created.intentContract.componentResolution.resolvedComponent | Should Be 'governed command API'
    $created.intentContract.componentResolution.outcomePreserved | Should Be $true
    @($created.intentContract.investigationEvidence).Count | Should BeGreaterThan 0
    $created.intentContract.questionCount | Should Be 0
    $created.intentResolutionReceipt.ready | Should Be $true
    $guard.ok | Should Be $true
    $guard.intentReceipt.current | Should Be $true
  }

  It 'rebinds the original governed task intent to a new root session without replacing the task' {
    $stateRoot = Join-Path $TestDrive 'intent-session-rebind'
    $workspaceKey = 'ws-i17171717171717171717171'
    $taskId = 'task-intent-session-rebind'
    $firstSession = 'sid-i17171717171717171717171a'
    $secondSession = 'sid-i17171717171717171717171b'
    $created = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$firstSession,'-InstructionMode','continue','-FocusId','notebook-ui','-NextAction','implement governed notebook editing','-LatestUserInstruction','add editable notebook without direct database writes','-IntentContractJson',(New-TestIntentJson),'-StateRoot',$stateRoot)
    $rebound = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$secondSession,'-RebindSession','-InstructionMode','continue','-FocusId','notebook-ui','-NextAction','continue the original governed notebook path','-LatestUserInstruction','continue the same notebook task after reconnect','-IntentContractJson',(New-TestIntentJson),'-StateRoot',$stateRoot)
    $newRead = Invoke-IntentContract -Arguments @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$secondSession,'-StateRoot',$stateRoot)
    $oldRead = Invoke-IntentContract -Arguments @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$firstSession,'-StateRoot',$stateRoot)

    $created.ok | Should Be $true
    $rebound.ok | Should Be $true
    $rebound.taskId | Should Be $taskId
    $rebound.taskInstanceId | Should Be $created.taskInstanceId
    $rebound.ownerSessionKey | Should Not Be $created.ownerSessionKey
    $rebound.intentSessionRebindReceipt.previousOwnerSessionKey | Should Be $created.ownerSessionKey
    $rebound.intentSessionRebindReceipt.newOwnerSessionKey | Should Be $rebound.ownerSessionKey
    $rebound.intentSessionRebindReceipt.latestReceiptId | Should Be $created.intentResolutionReceipt.receiptId
    $rebound.intentResolutionReceipt.ownerSessionKey | Should Be $rebound.ownerSessionKey
    $rebound.intentResolutionReceipt.receiptId | Should Not Be $created.intentResolutionReceipt.receiptId
    $newRead.ok | Should Be $true
    $newRead.taskInstanceId | Should Be $created.taskInstanceId
    $oldRead.ok | Should Be $false
    $oldRead.code | Should Be 'EXECUTION_CONTRACT_FOREIGN_SESSION'
  }

  It 'rejects a read-only downgrade when the requested outcome is editable governed access' {
    $stateRoot = Join-Path $TestDrive 'intent-governed-equivalent'
    $badIntent = [pscustomobject]@{
      schema = 'super-brain.intent-contract.v2'
      literalRequestDigest = 'editable notebook, but no direct database writes'
      resolvedOutcome = 'Show notes in the interface.'
      productRole = 'read-only notebook page'
      integrationObligations = @('local UI')
      materialUnknowns = @()
      compatibilityGuards = @('no browser-side direct SQLite or database writes')
      preservedCapabilities = @('read-only viewing')
      acceptanceCriteria = @('notes are visible')
      governedEquivalent = 'read-only page'
      autonomyTier = 'align'
      integrationMap = [pscustomobject]@{entryPoint='notebook page';userFlow='open page';domainOwner='UI';stateOwner='BrainControl';downstreamConsumers=@('reader');failureRecovery='reload';privacyPerformance='loopback';compatibilityMigration='legacy read';verification='page smoke';completionCondition='notes visible'}
      investigationEvidence = @('existing notebook flow')
      materialBranches = @()
      focusedQuestion = ''
      preserveExistingFlow = $true
      replacementReceipt = ''
      componentResolution = [pscustomobject]@{requestedComponent='editor';resolvedComponent='read-only page';outcomePreserved=$false;reason=''}
    } | ConvertTo-Json -Compress
    $rejected = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-read-only','-WorkspaceKey','ws-i22222222222222222222222','-SessionKey','sid-i22222222222222222222222','-FocusId','notebook-ui','-NextAction','build page','-IntentContractJson',$badIntent,'-StateRoot',$stateRoot)

    $rejected.ok | Should Be $false
    $rejected.code | Should Be 'EXECUTION_CONTRACT_INTENT_GOVERNED_EQUIVALENT_REQUIRED'
  }

  It 'requires repository or state investigation evidence without inventing a question' {
    $stateRoot = Join-Path $TestDrive 'intent-investigation'
    $candidate = New-TestIntentJson | ConvertFrom-Json
    $candidate.investigationEvidence = @()
    $missingEvidence = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-investigation-missing','-WorkspaceKey','ws-i23232323232323232323232','-SessionKey','sid-i23232323232323232323232','-FocusId','investigation-line','-NextAction','inspect current implementation','-LatestUserInstruction','use repository evidence before deciding whether to ask','-IntentContractJson',($candidate | ConvertTo-Json -Depth 10 -Compress),'-StateRoot',$stateRoot)

    $candidate.investigationEvidence = @('runtime/brain_control.py current command authority','existing notebook flow')
    $candidate.focusedQuestion = ''
    $candidate.materialBranches = @()
    $investigated = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-investigated','-WorkspaceKey','ws-i24242424242424242424242','-SessionKey','sid-i24242424242424242424242','-FocusId','investigation-line','-NextAction','use verified current implementation','-LatestUserInstruction','use repository evidence before deciding whether to ask','-IntentContractJson',($candidate | ConvertTo-Json -Depth 10 -Compress),'-StateRoot',$stateRoot)

    $missingEvidence.ok | Should Be $false
    $missingEvidence.code | Should Be 'EXECUTION_CONTRACT_INTENT_CONTRACT_INCOMPLETE'
    @($missingEvidence.missing) -contains 'investigationEvidence' | Should Be $true
    $investigated.ok | Should Be $true
    $investigated.intentContract.questionCount | Should Be 0
    @($investigated.intentContract.investigationEvidence).Count | Should Be 2
  }

  It 'asks exactly one focused question for two material product branches' {
    $stateRoot = Join-Path $TestDrive 'intent-material-branches'
    $candidate = New-TestIntentJson | ConvertFrom-Json
    $candidate.materialBranches = @('retain edits locally for 30 days','sync edits across devices indefinitely')
    $candidate.focusedQuestion = ''
    $missingQuestion = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-branches-missing','-WorkspaceKey','ws-i25252525252525252525252','-SessionKey','sid-i25252525252525252525252','-FocusId','branch-line','-NextAction','wait for product choice','-LatestUserInstruction','choose retention behavior for the editable notebook','-IntentContractJson',($candidate | ConvertTo-Json -Depth 10 -Compress),'-StateRoot',$stateRoot)

    $candidate.focusedQuestion = 'Should edits stay local for 30 days or sync across devices indefinitely?'
    $resolved = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-branches-current','-WorkspaceKey','ws-i26262626262626262626262','-SessionKey','sid-i26262626262626262626262','-FocusId','branch-line','-NextAction','wait for one focused choice','-LatestUserInstruction','choose retention behavior for the editable notebook','-IntentContractJson',($candidate | ConvertTo-Json -Depth 10 -Compress),'-StateRoot',$stateRoot)

    $missingQuestion.ok | Should Be $false
    @($missingQuestion.missing) -contains 'focusedQuestion' | Should Be $true
    $resolved.ok | Should Be $true
    @($resolved.intentContract.materialBranches).Count | Should Be 2
    $resolved.intentContract.questionCount | Should Be 1
  }

  It 'preserves the existing flow unless an explicit replacement receipt exists' {
    $stateRoot = Join-Path $TestDrive 'intent-replacement'
    $candidate = New-TestIntentJson | ConvertFrom-Json
    $candidate.preserveExistingFlow = $false
    $candidate.replacementReceipt = ''
    $unapproved = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-replacement-missing','-WorkspaceKey','ws-i27272727272727272727272','-SessionKey','sid-i27272727272727272727272','-FocusId','replacement-line','-NextAction','replace existing flow','-LatestUserInstruction','replace the existing notebook flow only with explicit approval','-IntentContractJson',($candidate | ConvertTo-Json -Depth 10 -Compress),'-StateRoot',$stateRoot)

    $candidate.replacementReceipt = 'user-approved replacement preserving governed editing and rollback'
    $approved = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-replacement-current','-WorkspaceKey','ws-i28282828282828282828282','-SessionKey','sid-i28282828282828282828282','-FocusId','replacement-line','-NextAction','apply approved replacement','-LatestUserInstruction','replace the existing notebook flow only with explicit approval','-IntentContractJson',($candidate | ConvertTo-Json -Depth 10 -Compress),'-StateRoot',$stateRoot)

    $unapproved.ok | Should Be $false
    @($unapproved.missing) -contains 'replacementReceipt' | Should Be $true
    $approved.ok | Should Be $true
    $approved.intentContract.preserveExistingFlow | Should Be $false
    $approved.intentContract.replacementReceipt | Should Match 'user-approved replacement'
  }

  It 'keeps an ordinary local task outside the structural intent gate' {
    $stateRoot = Join-Path $TestDrive 'intent-direct-task'
    $taskId = 'task-intent-direct'
    $workspaceKey = 'ws-i29292929292929292929292'
    $sessionKey = 'sid-i29292929292929292929292'
    $created = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','label-typo','-NextAction','fix the local label typo','-LatestUserInstruction','fix a typo in a label','-StateRoot',$stateRoot)
    $guard = Invoke-IntentContract -Arguments @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ProposedWorkId','label-typo','-ExpectedRevision',([string]$created.revision),'-ExpectedPlanFingerprint',([string]$created.planReceipt.planFingerprint),'-StateRoot',$stateRoot)

    $created.ok | Should Be $true
    $created.intentContractRequired | Should Be $false
    $guard.ok | Should Be $true
    $guard.intentReceipt.required | Should Be $false
  }

  It 'withholds a receipt after a newer instruction until intent is re-resolved' {
    $stateRoot = Join-Path $TestDrive 'intent-instruction-stale'
    $workspaceKey = 'ws-i33333333333333333333333'
    $sessionKey = 'sid-i33333333333333333333333'
    $taskId = 'task-intent-stale'
    $created = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','notebook-ui','-NextAction','implement governed notebook editing','-LatestUserInstruction','add editable notebook without direct database writes','-IntentContractJson',(New-TestIntentJson),'-StateRoot',$stateRoot)
    $observed = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','notebook-ui','-NextAction','export governed notebook','-LatestUserInstruction','also export the notebook','-StateRoot',$stateRoot)
    $guard = Invoke-IntentContract -Arguments @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ProposedWorkId','notebook-ui','-StateRoot',$stateRoot)

    $created.ok | Should Be $true
    $observed.ok | Should Be $true
    $guard.ok | Should Be $false
    $guard.code | Should Be 'EXECUTION_CONTRACT_INTENT_RECEIPT_STALE'
    @($guard.missing) -contains 'contractRevision' | Should Be $true
    @($guard.missing) -contains 'latestInstructionHash' | Should Be $true
  }

  It 'refreshes the intent receipt when explicit reconciliation continues the same governed work' {
    $stateRoot = Join-Path $TestDrive 'intent-explicit-reconciliation-current'
    $workspaceKey = 'ws-i33333333333333333333334'
    $sessionKey = 'sid-i33333333333333333333334'
    $taskId = 'task-intent-explicit-reconciliation-current'
    $created = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','notebook-ui','-NextAction','implement governed notebook editing','-LatestUserInstruction','add editable notebook without direct database writes','-IntentContractJson',(New-TestIntentJson),'-StateRoot',$stateRoot)
    $observed = Invoke-IntentContract -Arguments @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-UserInstruction','continue the governed notebook work after reconnect','-RequiresReconciliation','-StateRoot',$stateRoot)
    $reconciled = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','notebook-ui','-NextAction','finish the governed notebook path','-LatestUserInstruction','continue the governed notebook work after reconnect','-ExpectedRevision',([string]$observed.revision),'-ExpectedPlanFingerprint',([string]$observed.planReceipt.planFingerprint),'-TransitionId','intent-explicit-reconciliation-current','-StateRoot',$stateRoot)
    $guard = Invoke-IntentContract -Arguments @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ProposedWorkId','notebook-ui','-ExpectedRevision',([string]$reconciled.revision),'-ExpectedPlanFingerprint',([string]$reconciled.planReceipt.planFingerprint),'-RequireIntentContract','-StateRoot',$stateRoot)

    $created.ok | Should Be $true
    $observed.needsReconciliation | Should Be $true
    $reconciled.needsReconciliation | Should Be $false
    $reconciled.intentResolutionReceipt.contractRevision | Should Be $reconciled.revision
    $reconciled.intentResolutionReceipt.planFingerprint | Should Be $reconciled.planReceipt.planFingerprint
    $guard.ok | Should Be $true
    $guard.intentReceipt.current | Should Be $true
  }

  It 'rejects a receipt replayed across task scope and a foreign root session' {
    $stateRoot = Join-Path $TestDrive 'intent-replay'
    $workspaceKey = 'ws-i44444444444444444444444'
    $sessionKey = 'sid-i44444444444444444444444'
    $first = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-first','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','first-line','-NextAction','first action','-LatestUserInstruction','add editable notebook without direct database writes','-IntentContractJson',(New-TestIntentJson),'-StateRoot',$stateRoot)
    $second = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-second','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','second-line','-NextAction','second action','-LatestUserInstruction','add editable notebook without direct database writes','-IntentContractJson',(New-TestIntentJson),'-StateRoot',$stateRoot)
    $secondOnDisk = Get-Content -LiteralPath $second.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $secondOnDisk.intentResolutionReceipt = $first.intentResolutionReceipt
    Write-IntentTestJson $second.path $secondOnDisk
    $replayed = Invoke-IntentContract -Arguments @('-Action','Guard','-TaskId','task-intent-second','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ProposedWorkId','second-line','-StateRoot',$stateRoot)
    $foreign = Invoke-IntentContract -Arguments @('-Action','Guard','-TaskId','task-intent-second','-WorkspaceKey',$workspaceKey,'-SessionKey','sid-i44444444444444444444445','-ProposedWorkId','second-line','-StateRoot',$stateRoot)

    $replayed.ok | Should Be $false
    $replayed.code | Should Be 'EXECUTION_CONTRACT_INTENT_RECEIPT_STALE'
    @($replayed.missing) -contains 'taskId' | Should Be $true
    $foreign.ok | Should Be $false
    $foreign.code | Should Be 'EXECUTION_CONTRACT_SESSION_REBIND_REQUIRED'
  }

  It 'fails closed for material product unknowns while keeping preflight candidates non-authorizing' {
    $stateRoot = Join-Path $TestDrive 'intent-material-unknown'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $candidate = @(& $preflightScript -Query 'add a feature to the product workflow' -Json 2>$null) -join "`n" | ConvertFrom-Json
      $created = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId','task-intent-unknown','-WorkspaceKey','ws-i55555555555555555555555','-SessionKey','sid-i55555555555555555555555','-InstructionMode','continue','-FocusId','unknown-line','-NextAction','implement after decision','-LatestUserInstruction','add editable notebook without direct database writes','-IntentContractJson',(New-TestIntentJson @('choose retention owner')),'-StateRoot',$stateRoot)
      $guard = Invoke-IntentContract -Arguments @('-Action','Guard','-TaskId','task-intent-unknown','-WorkspaceKey','ws-i55555555555555555555555','-SessionKey','sid-i55555555555555555555555','-ProposedWorkId','unknown-line','-StateRoot',$stateRoot)

      $candidate.intentResolutionCandidate.authorizing | Should Be $false
      $candidate.intentResolutionCandidate.required | Should Be $true
      $guard.ok | Should Be $false
      $guard.code | Should Be 'EXECUTION_CONTRACT_INTENT_MATERIAL_UNKNOWN'
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }

  It 'reports a stale product receipt as a distinct cognitive enforcement failure' {
    $stateRoot = Join-Path $TestDrive 'intent-cognitive-enforce'
    $workspaceKey = 'ws-i66666666666666666666666'
    $sessionKey = 'sid-i66666666666666666666666'
    $taskId = 'task-intent-cognitive-enforce'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $created = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','notebook-ui','-NextAction','implement governed notebook editing','-LatestUserInstruction','add editable notebook without direct database writes','-IntentContractJson',(New-TestIntentJson),'-StateRoot',$stateRoot)
      $updated = Invoke-IntentContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','notebook-ui','-NextAction','export governed notebook','-LatestUserInstruction','also export the notebook','-StateRoot',$stateRoot)
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enforceScript -Query 'add a feature to the product workflow' -TaskId $taskId -SessionKey $sessionKey -ProposedWorkId 'notebook-ui' -Phase BeforeMutation -AllowMissingPreflight -Json 2>$null)
      $exitCode = $LASTEXITCODE
      $enforced = (($raw -join "`n") | ConvertFrom-Json)

      $created.ok | Should Be $true
      $updated.ok | Should Be $true
      $exitCode | Should Be 1
      $enforced.intentResolution.required | Should Be $true
      $enforced.intentResolution.ok | Should Be $false
      $enforced.intentResolution.code | Should Be 'EXECUTION_CONTRACT_INTENT_RECEIPT_STALE'
      @($enforced.violations) -contains 'intent-resolution-receipt' | Should Be $true
      $enforced.intentResolution.preflightDiagnosticOnly | Should Be $true
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'does not let a named collaborative task bypass intent binding when no contract exists' {
    $stateRoot = Join-Path $TestDrive 'intent-missing-contract'
    $workspaceKey = 'ws-i77777777777777777777777'
    $sessionKey = 'sid-i77777777777777777777777'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enforceScript -Query 'add a feature to the product workflow' -TaskId 'task-intent-missing' -SessionKey $sessionKey -ProposedWorkId 'new-feature' -Phase BeforeMutation -AllowMissingPreflight -Json 2>$null)
      $exitCode = $LASTEXITCODE
      $enforced = (($raw -join "`n") | ConvertFrom-Json)

      $exitCode | Should Be 1
      $enforced.intentResolution.required | Should Be $true
      $enforced.intentResolution.ok | Should Be $false
      @($enforced.violations) -contains 'execution-contract-guard' | Should Be $true
      @($enforced.violations) -contains 'intent-resolution-receipt' | Should Be $true
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }
}
