function Get-SuperBrainPhaseCloseoutText([string]$Value,[int]$Max=160) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ($Value.Trim() -replace '\s+',' ')
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Get-SuperBrainPhaseCloseoutHash([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { return '' }
}

function Test-SuperBrainPhaseCloseoutSha256([string]$Value) {
  return -not [string]::IsNullOrWhiteSpace($Value) -and $Value.ToLowerInvariant() -match '^[a-f0-9]{64}$'
}

function Test-SuperBrainPhaseCloseoutChildPath([string]$Parent,[string]$Child) {
  if ([string]::IsNullOrWhiteSpace($Parent) -or [string]::IsNullOrWhiteSpace($Child)) { return $false }
  try {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $childFull = [IO.Path]::GetFullPath($Child)
    return $childFull.StartsWith($parentFull,[StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function Get-SuperBrainFormalPhaseToken([string]$Phase) {
  if ([string]::IsNullOrWhiteSpace($Phase)) { return '' }
  $label = $Phase.Trim()
  $legacyMatch = [regex]::Match($label, '^(?i:p(?:hase)?)\s*(?<number>\d+(?:\.\d+){0,2})(?=$|\s|[/:()\-])')
  if ($legacyMatch.Success) { return 'P' + [string]$legacyMatch.Groups['number'].Value }

  # R<n> Stage <n> is a formal stage label, not free-form progress prose.
  # Normalize it before comparing contracts so an R5 Stage 9 -> R5 Stage 10
  # transition cannot bypass the same H7 closeout requirement as P9 -> P10.
  $releaseStageMatch = [regex]::Match($label, '^(?i:r(?<release>\d+))\s+(?i:stage)\s*(?<stage>\d+(?:\.\d+){0,2})(?=$|\s|[/:()\-])')
  if ($releaseStageMatch.Success) {
    return 'R' + [string]$releaseStageMatch.Groups['release'].Value + '-STAGE' + [string]$releaseStageMatch.Groups['stage'].Value
  }
  return ''
}

function Test-SuperBrainFormalPhase([string]$Phase) {
  return -not [string]::IsNullOrWhiteSpace((Get-SuperBrainFormalPhaseToken $Phase))
}

function Get-SuperBrainFormalPhaseDirection([string]$Previous,[string]$Next) {
  if ([string]::Equals($Previous,$Next,[StringComparison]::OrdinalIgnoreCase)) { return 'unchanged' }
  $legacy = [regex]::Match($Previous, '^P(?<number>\d+(?:\.\d+){0,2})$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  $nextLegacy = [regex]::Match($Next, '^P(?<number>\d+(?:\.\d+){0,2})$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($legacy.Success -and $nextLegacy.Success) {
    $previousParts = @($legacy.Groups['number'].Value.Split('.') | ForEach-Object { [int]$_ })
    $nextParts = @($nextLegacy.Groups['number'].Value.Split('.') | ForEach-Object { [int]$_ })
    $length = [Math]::Max($previousParts.Count,$nextParts.Count)
    for ($index = 0; $index -lt $length; $index++) {
      $left = if ($index -lt $previousParts.Count) { $previousParts[$index] } else { 0 }
      $right = if ($index -lt $nextParts.Count) { $nextParts[$index] } else { 0 }
      if ($right -gt $left) { return 'forward' }
      if ($right -lt $left) { return 'backward' }
    }
    return 'unchanged'
  }
  $release = [regex]::Match($Previous, '^R(?<release>\d+)-STAGE(?<stage>\d+(?:\.\d+){0,2})$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  $nextRelease = [regex]::Match($Next, '^R(?<release>\d+)-STAGE(?<stage>\d+(?:\.\d+){0,2})$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($release.Success -and $nextRelease.Success -and [int]$release.Groups['release'].Value -eq [int]$nextRelease.Groups['release'].Value) {
    $previousParts = @($release.Groups['stage'].Value.Split('.') | ForEach-Object { [int]$_ })
    $nextParts = @($nextRelease.Groups['stage'].Value.Split('.') | ForEach-Object { [int]$_ })
    $length = [Math]::Max($previousParts.Count,$nextParts.Count)
    for ($index = 0; $index -lt $length; $index++) {
      $left = if ($index -lt $previousParts.Count) { $previousParts[$index] } else { 0 }
      $right = if ($index -lt $nextParts.Count) { $nextParts[$index] } else { 0 }
      if ($right -gt $left) { return 'forward' }
      if ($right -lt $left) { return 'backward' }
    }
    return 'unchanged'
  }
  return 'changed'
}

function Get-SuperBrainPhaseCloseoutRequirement(
  [object]$PreviousContract,
  [string]$NextPhase,
  [string]$NextFocusId,
  [string]$InstructionMode
) {
  $previousPhaseLabel = if ($PreviousContract -and $PreviousContract.PSObject.Properties['currentPhase']) { [string]$PreviousContract.currentPhase } else { '' }
  $previousFocusId = if ($PreviousContract -and $PreviousContract.PSObject.Properties['focusId']) { [string]$PreviousContract.focusId } else { '' }
  $previousPhase = Get-SuperBrainFormalPhaseToken $previousPhaseLabel
  $nextFormalPhase = Get-SuperBrainFormalPhaseToken $NextPhase
  $phaseDirection = if (-not [string]::IsNullOrWhiteSpace($previousPhase) -and -not [string]::IsNullOrWhiteSpace($nextFormalPhase)) { Get-SuperBrainFormalPhaseDirection $previousPhase $nextFormalPhase } else { 'changed' }
  $changed = if (-not [string]::IsNullOrWhiteSpace($previousPhase) -and -not [string]::IsNullOrWhiteSpace($nextFormalPhase)) {
    -not [string]::Equals($previousPhase,$nextFormalPhase,[StringComparison]::OrdinalIgnoreCase)
  } else {
    -not [string]::Equals($previousPhaseLabel,$NextPhase,[StringComparison]::OrdinalIgnoreCase)
  }
  $sameLine = (-not [string]::IsNullOrWhiteSpace($previousFocusId) -and [string]::Equals($previousFocusId,$NextFocusId,[StringComparison]::OrdinalIgnoreCase))
  # A branch/replace mode only exempts a real work-line transition.  It must
  # never turn into a same-line escape hatch around a forward phase closeout.
  $exempt = ($InstructionMode -eq 'resume_parent' -or (($InstructionMode -in @('replace','side_branch')) -and -not $sameLine))
  return [pscustomobject]@{
    required = ($phaseDirection -in @('forward','changed') -and $changed -and $sameLine -and -not $exempt -and -not [string]::IsNullOrWhiteSpace($previousPhase))
    previousPhase = $previousPhase
    nextPhase = if (-not [string]::IsNullOrWhiteSpace($nextFormalPhase)) { $nextFormalPhase } else { $NextPhase }
    sameLine = $sameLine
    phaseDirection = $phaseDirection
    reason = if ($phaseDirection -eq 'backward') { 'phase_state_correction' } elseif ($phaseDirection -in @('forward','changed') -and $changed -and $sameLine -and -not $exempt -and -not [string]::IsNullOrWhiteSpace($previousPhase)) { 'formal_phase_exit' } elseif (-not $changed) { 'phase_unchanged' } elseif (-not $sameLine) { 'work_line_changed' } elseif ($exempt) { 'explicit_work_line_transition' } else { 'previous_phase_not_formal' }
  }
}

function Get-SuperBrainPhaseCloseoutEntries([object]$Contract) {
  if ($Contract -and $Contract.PSObject.Properties['phaseCloseouts'] -and $Contract.phaseCloseouts) { return @($Contract.phaseCloseouts) }
  return @()
}

function Test-SuperBrainRetiredPhaseEvidencePolicy([string]$Policy) {
  return $Policy -in @('host_user_attested','user_authorized_synthetic')
}

function Get-SuperBrainPhaseEvidencePolicy([object]$Contract) {
  if ($Contract -and $Contract.PSObject.Properties['phaseEvidencePolicy']) {
    $value = [string]$Contract.phaseEvidencePolicy
    if ($value -in @('h7_current','host_user_attested','user_authorized_synthetic')) { return $value }
  }
  return 'h7_current'
}

function New-SuperBrainPhaseCloseoutScope([object]$Contract,[string]$PackageVersion,[string]$Phase) {
  $progressProof = if ($Contract -and $Contract.PSObject.Properties['projectProgressProof']) { $Contract.projectProgressProof } else { $null }
  $visibleProgress = if ($Contract -and $Contract.PSObject.Properties['visibleProgressReceipt']) { $Contract.visibleProgressReceipt } else { $null }
  return [pscustomobject]@{
    taskId = if($Contract){[string]$Contract.taskId}else{''}
    workspaceKey = if($Contract){[string]$Contract.workspaceKey}else{''}
    ownerSessionKey = if($Contract -and $Contract.PSObject.Properties['ownerSessionKey']){[string]$Contract.ownerSessionKey}else{''}
    packageVersion = $PackageVersion
    contractRevision = if($Contract){[int]$Contract.revision}else{0}
    planFingerprint = if($Contract -and $Contract.PSObject.Properties['planReceipt'] -and $Contract.planReceipt){[string]$Contract.planReceipt.planFingerprint}else{''}
    phase = $Phase
    phaseEvidencePolicy = Get-SuperBrainPhaseEvidencePolicy $Contract
    projectProgressPayloadHash = if($progressProof){[string]$progressProof.payloadHash}else{''}
    visibleProgressPayloadHash = if($visibleProgress){[string]$visibleProgress.payloadHash}else{''}
  }
}

function Get-SuperBrainPhaseCloseoutPackageRoot {
  try {
    $sourceFile = [string](Get-Command -Name Get-SuperBrainPhaseCloseoutPackageRoot -ErrorAction Stop).ScriptBlock.File
    if ([string]::IsNullOrWhiteSpace($sourceFile)) { return '' }
    $internalRoot = Split-Path -Parent $sourceFile
    $scriptsRoot = Split-Path -Parent $internalRoot
    return (Split-Path -Parent $scriptsRoot)
  } catch { return '' }
}

function Get-SuperBrainPhaseCloseoutWorkspaceKey([string]$ProjectRoot) {
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  try {
    $normalized = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)) } finally { $sha.Dispose() }
    return 'ws-' + (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,24)
  } catch { return '' }
}

function Resolve-SuperBrainPhaseCloseoutProjectRoot([string]$ProjectRoot) {
  $candidate = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { [string](Get-Location).Path } else { $ProjectRoot }
  if ([string]::IsNullOrWhiteSpace($candidate)) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_PROJECT_ROOT_REQUIRED';path=''} }
  try { $full = [IO.Path]::GetFullPath($candidate) } catch { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_PROJECT_ROOT_INVALID';path=''} }
  if (-not (Test-Path -LiteralPath $full -PathType Container)) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_PROJECT_ROOT_INVALID';path=''} }
  return [pscustomobject]@{ok=$true;code='PHASE_CLOSEOUT_H7_PROJECT_ROOT_CURRENT';path=$full.TrimEnd('\','/')}
}

function Invoke-SuperBrainPhaseCloseoutH7Evidence(
  [object]$PreviousContract,
  [string]$WorkspaceRoot,
  [string]$PackageRoot = '',
  [string]$MemoryBase = '',
  [string]$ProjectRoot = ''
) {
  $scope = New-SuperBrainPhaseCloseoutScope $PreviousContract ([string]$PreviousContract.packageVersion) ([string]$PreviousContract.currentPhase)
  if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = Get-SuperBrainPhaseCloseoutPackageRoot }
  if ([string]::IsNullOrWhiteSpace($MemoryBase) -and -not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $MemoryBase = Split-Path -Parent $WorkspaceRoot }
  $root = Resolve-SuperBrainPhaseCloseoutProjectRoot $ProjectRoot
  if (-not $root.ok) { return $root }
  if ([string]::IsNullOrWhiteSpace($PackageRoot) -or -not (Test-Path -LiteralPath (Join-Path $PackageRoot 'runtime\brain_cli.py') -PathType Leaf)) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_CLI_UNAVAILABLE'}
  }
  if ([string]::IsNullOrWhiteSpace($MemoryBase) -or -not (Test-Path -LiteralPath $MemoryBase -PathType Container)) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_MEMORY_BASE_UNAVAILABLE'}
  }
  $actualWorkspaceKey = Get-SuperBrainPhaseCloseoutWorkspaceKey $root.path
  if ([string]::IsNullOrWhiteSpace($actualWorkspaceKey) -or -not [string]::Equals($actualWorkspaceKey,[string]$scope.workspaceKey,[StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_PROJECT_SCOPE_MISMATCH'}
  }
  if ([string]::IsNullOrWhiteSpace([string]$scope.ownerSessionKey)) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_SESSION_REQUIRED'} }
  $python = Get-Command python -ErrorAction SilentlyContinue
  if (-not $python) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_CLI_UNAVAILABLE'} }
  $previousThread = $env:CODEX_THREAD_ID
  $previousState = $env:SUPER_BRAIN_STATE_ROOT
  $raw = @()
  $exitCode = 1
  try {
    $env:CODEX_THREAD_ID = [string]$scope.ownerSessionKey
    $env:SUPER_BRAIN_STATE_ROOT = $MemoryBase
    Push-Location -LiteralPath $root.path
    $raw = @(& $python.Source -X utf8 (Join-Path $PackageRoot 'runtime\brain_cli.py') --package-root $PackageRoot --memory-root (Join-Path $MemoryBase 'shared') turn-runtime --phase evidence --memory-mode auto --turn-intent continuity --timeout-seconds 12 2>$null)
    $exitCode = $LASTEXITCODE
  } catch {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_EVIDENCE_CLI_FAILED'}
  } finally {
    try { Pop-Location } catch {}
    if ($null -eq $previousThread) { Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue } else { $env:CODEX_THREAD_ID = $previousThread }
    if ($null -eq $previousState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousState }
  }
  if ($exitCode -ne 0) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_EVIDENCE_CLI_FAILED'} }
  try { $evidence = (($raw -join "`n").Trim() | ConvertFrom-Json -ErrorAction Stop) } catch { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_EVIDENCE_INVALID'} }
  if (-not $evidence -or $evidence.ok -ne $true -or [string]$evidence.mode -ne 'hookless_turn_runtime' -or [string]$evidence.phase -ne 'evidence') {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_EVIDENCE_INVALID'}
  }
  if ($evidence.available -ne $true -or [string]$evidence.code -ne 'H7_EVIDENCE_CURRENT') {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_EVIDENCE_NOT_CURRENT';h7Code=[string]$evidence.code}
  }
  $retiredTransportCurrent = $false
  if ($evidence.PSObject.Properties['retiredTransportGuard'] -and $evidence.retiredTransportGuard) {
    $guard = $evidence.retiredTransportGuard
    $retiredTransportCurrent = (
      [string]$guard.schema -eq 'super-brain.retired-transport-guard.v1' -and
      [string]$guard.state -eq 'ready' -and
      [string]$guard.legacyDependency -eq 'none' -and
      $guard.h7Transport -and [string]$guard.h7Transport.mode -eq 'hookless_turn_runtime'
    )
  } elseif ($evidence.PSObject.Properties['p7'] -and $evidence.p7) {
    # Compatibility for evidence produced before the retired-transport guard
    # projection was introduced.  It is still a rejection proof, never a
    # usable P7 evidence path.
    $retiredTransportCurrent = [string]$evidence.p7.state -eq 'retired'
  }
  if ($evidence.rawPromptStored -ne $false -or $evidence.rawTranscriptStored -ne $false -or -not $retiredTransportCurrent) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_RETIREMENT_STATE_INVALID'}
  }
  if (-not $evidence.scope -or [string]$evidence.scope.taskId -ne [string]$scope.taskId -or [string]$evidence.scope.workspaceKey -ne [string]$scope.workspaceKey -or [int]$evidence.scope.contractRevision -ne [int]$scope.contractRevision -or -not (Test-SuperBrainPhaseCloseoutSha256 ([string]$evidence.scope.contractHash))) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_SCOPE_MISMATCH'}
  }
  if (-not $evidence.entry -or $evidence.entry.current -ne $true -or -not $evidence.entry.receipt -or [string]$evidence.entry.receipt.phase -ne 'open' -or -not (Test-SuperBrainPhaseCloseoutSha256 ([string]$evidence.entry.receipt.receiptHash))) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_ENTRY_NOT_CURRENT'}
  }
  if (-not $evidence.telemetry -or $evidence.telemetry.current -ne $true -or -not (Test-SuperBrainPhaseCloseoutSha256 ([string]$evidence.telemetry.payloadHash))) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_TELEMETRY_NOT_CURRENT'}
  }
  if (-not $evidence.projectProgress -or [string]$evidence.projectProgress.state -ne 'current' -or -not (Test-SuperBrainPhaseCloseoutSha256 ([string]$evidence.projectProgress.payloadHash)) -or [string]$evidence.projectProgress.payloadHash -ne [string]$scope.projectProgressPayloadHash) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_PROJECT_PROGRESS_NOT_CURRENT'}
  }
  if (-not $evidence.visibleProgress -or [string]$evidence.visibleProgress.state -ne 'current' -or [string]$evidence.visibleProgress.source -ne 'assistant_visible_reply' -or $evidence.visibleProgress.continuationEligible -ne $true -or -not (Test-SuperBrainPhaseCloseoutSha256 ([string]$evidence.visibleProgress.payloadHash)) -or [string]$evidence.visibleProgress.payloadHash -ne [string]$scope.visibleProgressPayloadHash) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_VISIBLE_PROGRESS_NOT_CURRENT'}
  }

  # The open receipt and telemetry are transport snapshots, not the durable
  # stage truth.  A normal H7 open (for example after publishing a stage
  # receipt) legitimately refreshes those snapshots while keeping the same
  # contract revision, project proof, and visible-progress receipt.  Preserve
  # the recent open receipt hashes so a closeout can be checked against the
  # exact H7 evidence that created it without making a harmless later open
  # invalidate the stage transition.
  $entryReceiptHistory = @()
  try {
    $telemetryPath = Join-Path $MemoryBase ("workspace\runtime-state\turn-runtime\telemetry\" + [string]$evidence.scope.scopeRef + '.json')
    if (Test-Path -LiteralPath $telemetryPath -PathType Leaf) {
      $telemetryRecord = Get-Content -LiteralPath $telemetryPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($telemetryRecord -and $telemetryRecord.PSObject.Properties['events'] -and $telemetryRecord.events) {
        $entryReceiptHistory = @($telemetryRecord.events | ForEach-Object { [string]$_.receiptHash } | Where-Object { Test-SuperBrainPhaseCloseoutSha256 $_ } | Select-Object -Unique)
      }
    }
  } catch { $entryReceiptHistory = @() }
  return [pscustomobject]@{
    ok=$true
    value=[pscustomobject]@{
      mode='hookless_turn_runtime'
      scopeRef=[string]$evidence.scope.scopeRef
      contractHash=[string]$evidence.scope.contractHash
      entryReceiptHash=[string]$evidence.entry.receipt.receiptHash
      telemetryPayloadHash=[string]$evidence.telemetry.payloadHash
      projectProgressPayloadHash=[string]$evidence.projectProgress.payloadHash
      visibleProgressPayloadHash=[string]$evidence.visibleProgress.payloadHash
      entryReceiptHistory=@($entryReceiptHistory)
    }
  }
}

function Test-SuperBrainPhaseCloseoutH7Binding([object]$Binding,[object]$Current) {
  if (-not $Binding -or -not $Current -or [string]$Binding.mode -ne 'hookless_turn_runtime') { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_BINDING_INVALID'} }
  # Contract/proof/visible-progress hashes are durable stage truth and must
  # match exactly.  Entry/telemetry hashes are bounded H7 transport snapshots;
  # they may be refreshed by a later normal open, but only when the original
  # entry receipt is present in the retained H7 telemetry history.  This keeps
  # closeout atomic without accepting a fabricated/tampered entry hash.
  foreach ($name in @('scopeRef','contractHash','projectProgressPayloadHash','visibleProgressPayloadHash')) {
    if (-not $Binding.PSObject.Properties[$name] -or -not (Test-SuperBrainPhaseCloseoutSha256 ([string]$Binding.$name))) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_BINDING_INVALID'} }
    if ([string]$Binding.$name -ne [string]$Current.$name) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_BINDING_MISMATCH'} }
  }
  foreach ($name in @('entryReceiptHash','telemetryPayloadHash')) {
    if (-not $Binding.PSObject.Properties[$name] -or -not (Test-SuperBrainPhaseCloseoutSha256 ([string]$Binding.$name))) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_BINDING_INVALID'} }
  }
  $entryMatchesCurrent = [string]$Binding.entryReceiptHash -eq [string]$Current.entryReceiptHash
  $telemetryMatchesCurrent = [string]$Binding.telemetryPayloadHash -eq [string]$Current.telemetryPayloadHash
  if (-not $entryMatchesCurrent -or -not $telemetryMatchesCurrent) {
    $history = if ($Current.PSObject.Properties['entryReceiptHistory']) { @($Current.entryReceiptHistory) } else { @() }
    if (-not $entryMatchesCurrent -and [string]$Binding.entryReceiptHash -notin $history) {
      return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_BINDING_MISMATCH'}
    }
  }
  return [pscustomobject]@{ok=$true}
}

function Test-SuperBrainPhaseCloseoutHostStageReceipt(
  [object]$Receipt,
  [object]$PreviousContract,
  [object]$Requirement,
  [object]$Current
) {
  if (-not $Receipt -or -not $Receipt.PSObject.Properties['hostStageReceipt'] -or -not $Receipt.hostStageReceipt) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_HOST_STAGE_RECEIPT_REQUIRED'}
  }
  $hostStage = $Receipt.hostStageReceipt
  $expectedNames = @('schema','observationSource','taskId','workspaceKey','ownerSessionKey','phase','contractRevision','planFingerprint','scopeRef','visibleProgressPayloadHash','h7EntryReceiptHash','state','rawPromptStored','rawTranscriptStored')
  $actualNames = @($hostStage.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
  $expectedNames = @($expectedNames | Sort-Object)
  if ($actualNames.Count -ne $expectedNames.Count -or (Compare-Object $actualNames $expectedNames)) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_HOST_STAGE_RECEIPT_INVALID'} }
  $planFingerprint = if ($PreviousContract -and $PreviousContract.PSObject.Properties['planReceipt'] -and $PreviousContract.planReceipt) { [string]$PreviousContract.planReceipt.planFingerprint } else { '' }
  if (
    [string]$hostStage.schema -ne 'super-brain.host-stage-receipt.v1' -or
    [string]$hostStage.observationSource -ne 'codex_app_read_thread' -or
    [string]$hostStage.taskId -ne [string]$PreviousContract.taskId -or
    [string]$hostStage.workspaceKey -ne [string]$PreviousContract.workspaceKey -or
    [string]$hostStage.ownerSessionKey -ne [string]$PreviousContract.ownerSessionKey -or
    -not [string]::Equals([string]$hostStage.phase,[string]$Requirement.previousPhase,[StringComparison]::OrdinalIgnoreCase) -or
    [int]$hostStage.contractRevision -ne [int]$PreviousContract.revision -or
    [string]$hostStage.planFingerprint -ne $planFingerprint -or
    [string]$hostStage.scopeRef -ne [string]$Current.scopeRef -or
    [string]$hostStage.visibleProgressPayloadHash -ne [string]$Current.visibleProgressPayloadHash -or
    (
      [string]$hostStage.h7EntryReceiptHash -ne [string]$Current.entryReceiptHash -and
      [string]$hostStage.h7EntryReceiptHash -notin @($Current.entryReceiptHistory)
    ) -or
    [string]$hostStage.state -ne 'observed' -or
    $hostStage.rawPromptStored -ne $false -or
    $hostStage.rawTranscriptStored -ne $false
  ) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_HOST_STAGE_RECEIPT_MISMATCH'} }
  foreach ($name in @('scopeRef','visibleProgressPayloadHash','h7EntryReceiptHash')) {
    if (-not (Test-SuperBrainPhaseCloseoutSha256 ([string]$hostStage.$name))) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_HOST_STAGE_RECEIPT_INVALID'} }
  }
  return [pscustomobject]@{ok=$true;value=[pscustomobject]@{
    schema='super-brain.host-stage-receipt.v1'
    observationSource='codex_app_read_thread'
    taskId=[string]$PreviousContract.taskId
    workspaceKey=[string]$PreviousContract.workspaceKey
    ownerSessionKey=[string]$PreviousContract.ownerSessionKey
    phase=[string]$Requirement.previousPhase
    contractRevision=[int]$PreviousContract.revision
    planFingerprint=$planFingerprint
    scopeRef=[string]$Current.scopeRef
    visibleProgressPayloadHash=[string]$Current.visibleProgressPayloadHash
    h7EntryReceiptHash=[string]$Current.entryReceiptHash
    state='observed'
    rawPromptStored=$false
    rawTranscriptStored=$false
  }}
}

function Test-SuperBrainPhaseCloseoutRetiredReceipt([object]$Receipt) {
  if (-not $Receipt) { return $false }
  if ([string]$Receipt.schema -eq 'super-brain.phase-closeout-receipt.v1') { return $true }
  foreach ($name in @('realUserPath','syntheticNativePath','counterexample','promptHook','nativePromptHook','phaseBehaviorEvidence')) {
    if ($Receipt.PSObject.Properties[$name]) { return $true }
  }
  return (Test-SuperBrainRetiredPhaseEvidencePolicy ([string]$Receipt.phaseEvidencePolicy))
}

function ConvertTo-SuperBrainPhaseCloseoutRecord(
  [object]$Receipt,
  [string]$ReceiptPath,
  [object]$PreviousContract,
  [string]$WorkspaceRoot,
  [string]$PackageVersion,
  [object]$Requirement,
  [string]$PackageRoot = '',
  [string]$MemoryBase = '',
  [string]$ProjectRoot = ''
) {
  $expectedTaskId = [string]$PreviousContract.taskId
  $expectedWorkspaceKey = [string]$PreviousContract.workspaceKey
  $expectedSessionKey = if ($PreviousContract.PSObject.Properties['ownerSessionKey']) { [string]$PreviousContract.ownerSessionKey } else { '' }
  $expectedRevision = [int]$PreviousContract.revision
  $expectedPlanFingerprint = if ($PreviousContract.PSObject.Properties['planReceipt'] -and $PreviousContract.planReceipt) { [string]$PreviousContract.planReceipt.planFingerprint } else { '' }
  $scope = New-SuperBrainPhaseCloseoutScope $PreviousContract $PackageVersion ([string]$Requirement.previousPhase)
  if (Test-SuperBrainPhaseCloseoutRetiredReceipt $Receipt) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_RETIRED_P7_EVIDENCE' } }
  if ([string]$Receipt.schema -eq 'super-brain.phase-closeout-receipt.v2') { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_HOST_STAGE_RECEIPT_REQUIRED' } }
  if ([string]$Receipt.schema -ne 'super-brain.phase-closeout-receipt.v3') { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_SCHEMA_INVALID' } }
  if ([string]$Receipt.taskId -ne $expectedTaskId -or [string]$Receipt.workspaceKey -ne $expectedWorkspaceKey -or [string]$Receipt.ownerSessionKey -ne $expectedSessionKey) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_SCOPE_MISMATCH' } }
  if ([string]$Receipt.packageVersion -ne $PackageVersion) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_VERSION_MISMATCH' } }
  if (-not [string]::Equals([string]$Receipt.phase,[string]$Requirement.previousPhase,[StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_PHASE_MISMATCH' } }
  if ([int]$Receipt.contractRevision -ne $expectedRevision -or [string]$Receipt.planFingerprint -ne $expectedPlanFingerprint) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_BINDING_MISMATCH' } }
  if ([string]$Receipt.decision -ne 'accepted' -or $Receipt.rawPromptStored -ne $false -or $Receipt.rawTranscriptStored -ne $false) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_DECISION_INVALID' } }
  if ([string]$scope.phaseEvidencePolicy -ne 'h7_current' -or [string]$Receipt.phaseEvidencePolicy -ne 'h7_current') { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_EVIDENCE_POLICY_MISMATCH' } }
  $current = Invoke-SuperBrainPhaseCloseoutH7Evidence $PreviousContract $WorkspaceRoot $PackageRoot $MemoryBase $ProjectRoot
  if (-not $current.ok) { return $current }
  $binding = if ($Receipt.PSObject.Properties['h7']) { Test-SuperBrainPhaseCloseoutH7Binding $Receipt.h7 $current.value } else { [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_BINDING_REQUIRED'} }
  if (-not $binding.ok) { return $binding }
  $hostReceipt = Test-SuperBrainPhaseCloseoutHostStageReceipt $Receipt $PreviousContract $Requirement $current.value
  if (-not $hostReceipt.ok) { return $hostReceipt }
  return [pscustomobject]@{
    ok=$true
    value=[pscustomobject]@{
      schema='super-brain.phase-closeout.v3'
      phase=[string]$Requirement.previousPhase
      nextPhase=[string]$Requirement.nextPhase
      taskId=$expectedTaskId
      workspaceKey=$expectedWorkspaceKey
      ownerSessionKey=$expectedSessionKey
      packageVersion=$PackageVersion
      contractRevision=$expectedRevision
      planFingerprint=$expectedPlanFingerprint
      phaseEvidencePolicy='h7_current'
      decision='accepted'
      receiptFileName=[IO.Path]::GetFileName($ReceiptPath)
      receiptSha256=(Get-SuperBrainPhaseCloseoutHash $ReceiptPath)
      h7=$current.value
      hostStageReceipt=$hostReceipt.value
      verifiedAt=(Get-SuperBrainUtcTimestamp)
      rawPromptStored=$false
      rawTranscriptStored=$false
    }
  }
}

function Resolve-SuperBrainPhaseCloseouts(
  [object]$PreviousContract,
  [string]$NextPhase,
  [string]$NextFocusId,
  [string]$InstructionMode,
  [string]$ReceiptPath,
  [string]$WorkspaceRoot,
  [string]$PackageVersion,
  [string]$PackageRoot = '',
  [string]$MemoryBase = '',
  [string]$ProjectRoot = ''
) {
  $requirement = Get-SuperBrainPhaseCloseoutRequirement $PreviousContract $NextPhase $NextFocusId $InstructionMode
  $existing = @(Get-SuperBrainPhaseCloseoutEntries $PreviousContract)
  if (-not $requirement.required) {
    if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_NOT_REQUIRED'; requirement=$requirement } }
    return [pscustomobject]@{ ok=$true; closeouts=$existing; requirement=$requirement; added=$false }
  }
  $policy = Get-SuperBrainPhaseEvidencePolicy $PreviousContract
  if (Test-SuperBrainRetiredPhaseEvidencePolicy $policy) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_RETIRED_P7_EVIDENCE';requirement=$requirement} }
  if ($policy -ne 'h7_current') { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_EVIDENCE_POLICY_MISMATCH';requirement=$requirement} }
  if ([string]::IsNullOrWhiteSpace($ReceiptPath)) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_REQUIRED'; requirement=$requirement } }
  $evidenceRoot = Join-Path $WorkspaceRoot 'runtime-state\phase-evidence'
  if (-not (Test-SuperBrainPhaseCloseoutChildPath $evidenceRoot $ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_RECEIPT_PATH_INVALID'; requirement=$requirement }
  }
  try {
    if ((Get-Item -LiteralPath $ReceiptPath).Length -gt 65536) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_RECEIPT_TOO_LARGE'; requirement=$requirement } }
    $receipt = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_RECEIPT_INVALID'; requirement=$requirement } }
  $normalized = ConvertTo-SuperBrainPhaseCloseoutRecord $receipt $ReceiptPath $PreviousContract $WorkspaceRoot $PackageVersion $requirement $PackageRoot $MemoryBase $ProjectRoot
  if (-not $normalized.ok) { $normalized | Add-Member -NotePropertyName requirement -NotePropertyValue $requirement -Force; return $normalized }
  $duplicate = @($existing | Where-Object { [string]$_.phase -eq [string]$normalized.value.phase -and [int]$_.contractRevision -eq [int]$normalized.value.contractRevision -and [string]$_.planFingerprint -eq [string]$normalized.value.planFingerprint })
  if ($duplicate.Count -gt 0) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_ALREADY_RECORDED'; requirement=$requirement } }
  return [pscustomobject]@{ ok=$true; closeouts=@($existing + @($normalized.value) | Select-Object -Last 12); requirement=$requirement; added=$true; closeout=$normalized.value }
}

function Assert-SuperBrainPhaseCloseoutTransition(
  [object]$PreviousContract,
  [object]$CandidateContract,
  [string]$WorkspaceRoot,
  [string]$PackageVersion,
  [string]$PackageRoot = '',
  [string]$MemoryBase = '',
  [string]$ProjectRoot = ''
) {
  $nextPhase = if ($CandidateContract -and $CandidateContract.PSObject.Properties['currentPhase']) { [string]$CandidateContract.currentPhase } else { '' }
  $nextFocusId = if ($CandidateContract -and $CandidateContract.PSObject.Properties['focusId']) { [string]$CandidateContract.focusId } else { '' }
  $mode = if ($CandidateContract -and $CandidateContract.PSObject.Properties['instructionMode']) { [string]$CandidateContract.instructionMode } else { '' }
  $requirement = Get-SuperBrainPhaseCloseoutRequirement $PreviousContract $nextPhase $nextFocusId $mode
  if (-not $requirement.required) { return [pscustomobject]@{ ok=$true; requirement=$requirement } }
  $policy = Get-SuperBrainPhaseEvidencePolicy $PreviousContract
  if (Test-SuperBrainRetiredPhaseEvidencePolicy $policy) { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_RETIRED_P7_EVIDENCE';requirement=$requirement} }
  if ($policy -ne 'h7_current') { return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_EVIDENCE_POLICY_MISMATCH';requirement=$requirement} }
  $candidateCloseouts = @(Get-SuperBrainPhaseCloseoutEntries $CandidateContract)
  $matches = @($candidateCloseouts | Where-Object { [string]$_.phase -eq [string]$requirement.previousPhase -and [int]$_.contractRevision -eq [int]$PreviousContract.revision -and [string]$_.planFingerprint -eq [string]$PreviousContract.planReceipt.planFingerprint })
  if ($matches.Count -ne 1) { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_REQUIRED'; requirement=$requirement } }
  $record = $matches[0]
  if ([string]$record.schema -eq 'super-brain.phase-closeout.v1' -or (Test-SuperBrainPhaseCloseoutRetiredReceipt $record)) {
    return [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_RETIRED_P7_EVIDENCE';requirement=$requirement}
  }
  if ([string]$record.schema -eq 'super-brain.phase-closeout.v2') { return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_HOST_STAGE_RECEIPT_REQUIRED'; requirement=$requirement } }
  if ([string]$record.schema -ne 'super-brain.phase-closeout.v3' -or [string]$record.taskId -ne [string]$PreviousContract.taskId -or [string]$record.workspaceKey -ne [string]$PreviousContract.workspaceKey -or [string]$record.ownerSessionKey -ne [string]$PreviousContract.ownerSessionKey -or [string]$record.packageVersion -ne $PackageVersion -or [string]$record.decision -ne 'accepted' -or [string]$record.phaseEvidencePolicy -ne 'h7_current' -or $record.rawPromptStored -ne $false -or $record.rawTranscriptStored -ne $false) {
    return [pscustomobject]@{ ok=$false; code='PHASE_CLOSEOUT_RECORD_INVALID'; requirement=$requirement }
  }
  $current = Invoke-SuperBrainPhaseCloseoutH7Evidence $PreviousContract $WorkspaceRoot $PackageRoot $MemoryBase $ProjectRoot
  if (-not $current.ok) { $current | Add-Member -NotePropertyName requirement -NotePropertyValue $requirement -Force; return $current }
  $binding = if ($record.PSObject.Properties['h7']) { Test-SuperBrainPhaseCloseoutH7Binding $record.h7 $current.value } else { [pscustomobject]@{ok=$false;code='PHASE_CLOSEOUT_H7_BINDING_REQUIRED'} }
  if (-not $binding.ok) { $binding | Add-Member -NotePropertyName requirement -NotePropertyValue $requirement -Force; return $binding }
  $hostReceipt = Test-SuperBrainPhaseCloseoutHostStageReceipt $record $PreviousContract $requirement $current.value
  if (-not $hostReceipt.ok) { $hostReceipt | Add-Member -NotePropertyName requirement -NotePropertyValue $requirement -Force; return $hostReceipt }
  return [pscustomobject]@{ ok=$true; requirement=$requirement; closeout=$record }
}
