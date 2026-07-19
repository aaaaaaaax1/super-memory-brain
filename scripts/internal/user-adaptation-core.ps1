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

function Get-UserAdaptationState([string]$Root, [string]$WorkspaceRoot = '') {
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  $policy = Get-UserAdaptationPolicy $Root
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
  return [pscustomobject]@{ habitKey=$HabitKey; value=$Value; directive=$directive; contexts=$contexts }
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
    [string]$WorkspaceRoot = ''
  )
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
  param([string]$Root,[string]$WorkspaceRoot='')
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

function Set-UserAdaptationEnabled([string]$Root,[bool]$Enabled,[string]$WorkspaceRoot='') {
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
  New-Item -ItemType Directory -Force -Path $paths.directory | Out-Null
  $state = [pscustomobject]@{ schema='super-brain.user-adaptation-state.v1'; enabled=$Enabled; updatedAt=(Get-Date).ToString('o'); rawPromptStored=$false }
  Write-UserAdaptationJson $paths.state $state 8
  return [pscustomobject]@{ ok=$true; action=if($Enabled){'Enable'}else{'Disable'}; enabled=$Enabled; rawPromptStored=$false }
}

function Remove-UserAdaptationPreference([string]$Root,[string]$PreferenceId,[string]$WorkspaceRoot='') {
  if ([string]::IsNullOrWhiteSpace($PreferenceId)) { throw 'USER_ADAPTATION_PREFERENCE_ID_REQUIRED' }
  $policy = Get-UserAdaptationPolicy $Root
  $paths = Get-UserAdaptationPaths $Root $WorkspaceRoot
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
  $policy=Get-UserAdaptationPolicy $Root; $paths=Get-UserAdaptationPaths $Root $WorkspaceRoot; $defaults=New-UserAdaptationStoreDefaults
  $state=Get-UserAdaptationState $Root $WorkspaceRoot; $observations=Read-UserAdaptationJson $paths.observations $defaults.observations; $candidates=Read-UserAdaptationJson $paths.candidates $defaults.candidates; $profile=Read-UserAdaptationJson $paths.profile $defaults.profile
  return [pscustomobject]@{ok=$true;action='Status';schema='super-brain.user-adaptation-status.v1';enabled=[bool]$state.enabled;observationCount=@($observations.items).Count;candidateCount=@($candidates.items).Count;activePreferenceCount=@($profile.entries|Where-Object{$_.status-eq'active'}).Count;profileChars=if(Test-Path -LiteralPath $paths.profile){(Get-Item -LiteralPath $paths.profile).Length}else{0};profilePressure=[string]$profile.profilePressure;budgets=[pscustomobject]@{maxObservations=[int]$policy.storage.maxObservations;maxCandidates=[int]$policy.storage.maxCandidates;maxStablePreferences=[int]$policy.storage.maxStablePreferences;maxProfileChars=[int]$policy.storage.maxProfileChars;maxDirectives=[int]$policy.packet.maxDirectives;maxTokens=[int]$policy.packet.maxTokens};rawPromptStored=$false;directory=$paths.directory}
}
