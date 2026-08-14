function ConvertTo-SuperBrainCodexHookTimestamp([object]$Value) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  try {
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new(([DateTime]$Value).ToUniversalTime()) }
    return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
  } catch { return $null }
}

function ConvertTo-SuperBrainCodexHookInt([object]$Value) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 0 }
  $parsed = 0
  if ([int]::TryParse([string]$Value,[ref]$parsed)) { return $parsed }
  return 0
}

function Get-SuperBrainCodexHookProcessSnapshot {
  $names = @('ChatGPT','codex','codex-code-mode-host')
  $items = @()
  foreach ($process in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName })) {
    try {
      $started = [DateTimeOffset]::new($process.StartTime.ToUniversalTime())
      $items += [pscustomobject]@{ processName=[string]$process.ProcessName; id=[int]$process.Id; startTime=$started.ToString('o') }
    } catch { }
  }
  return @($items)
}

function Read-SuperBrainCodexHookEntryReceipt([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-SuperBrainCodexHookHostState {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][DateTimeOffset]$InstalledAt,
    [Parameter(Mandatory=$true)][string]$HandlerGeneration,
    [Parameter(Mandatory=$true)][string]$EntryReceiptPath,
    [object]$HookConfigChangeAt,
    [object[]]$ProcessSnapshot
  )

  $hookConfigBoundary = if ($PSBoundParameters.ContainsKey('HookConfigChangeAt')) { ConvertTo-SuperBrainCodexHookTimestamp $HookConfigChangeAt } else { $InstalledAt }
  if (-not $hookConfigBoundary) { $hookConfigBoundary = $InstalledAt }
  $evidenceNotBefore = if ($hookConfigBoundary.ToUniversalTime() -gt $InstalledAt.ToUniversalTime()) { $hookConfigBoundary } else { $InstalledAt }
  $processes = if ($PSBoundParameters.ContainsKey('ProcessSnapshot')) { @($ProcessSnapshot) } else { @(Get-SuperBrainCodexHookProcessSnapshot) }
  $normalizedProcesses = @()
  foreach ($process in $processes) {
    if (-not $process) { continue }
    $started = ConvertTo-SuperBrainCodexHookTimestamp $process.startTime
    if (-not $started) { continue }
    $normalizedProcesses += [pscustomobject]@{
       processName = [string]$process.processName
       id = if ($process.PSObject.Properties['id']) { ConvertTo-SuperBrainCodexHookInt $process.id } else { 0 }
       startTime = $started.ToUniversalTime().ToString('o')
       predatesInstall = ($started.ToUniversalTime() -lt $InstalledAt.ToUniversalTime())
       predatesHookConfigChange = ($started.ToUniversalTime() -lt $hookConfigBoundary.ToUniversalTime())
     }
   }

  $entry = Read-SuperBrainCodexHookEntryReceipt $EntryReceiptPath
  $entryObservedAt = if ($entry -and $entry.PSObject.Properties['observedAt']) { ConvertTo-SuperBrainCodexHookTimestamp $entry.observedAt } else { $null }
  $entryParentProcessId = if ($entry -and $entry.PSObject.Properties['parentProcessId']) { ConvertTo-SuperBrainCodexHookInt $entry.parentProcessId } else { 0 }
  $entryParentActive = ($entryParentProcessId -gt 0 -and @($normalizedProcesses | Where-Object { $_.id -eq $entryParentProcessId }).Count -gt 0)
  $reportedHostProcessId = if ($entry -and $entry.PSObject.Properties['hostProcessId']) { ConvertTo-SuperBrainCodexHookInt $entry.hostProcessId } else { 0 }
  $entryHostProcessId = if ($reportedHostProcessId -gt 0) { $reportedHostProcessId } else { $entryParentProcessId }
  $entryHostProcessName = if ($entry -and $entry.PSObject.Properties['hostProcessName']) { [string]$entry.hostProcessName } else { '' }
  $entryHostProcessDepth = if ($entry -and $entry.PSObject.Properties['hostProcessDepth']) { ConvertTo-SuperBrainCodexHookInt $entry.hostProcessDepth } else { 0 }
  $entryHostProcessSource = if ($entry -and $entry.PSObject.Properties['hostProcessSource']) { [string]$entry.hostProcessSource } else { '' }
  $entryDesktopCommandChainVerified = [bool](
    $entry -and
    $entry.PSObject.Properties['desktopCommandChainVerified'] -and
    $entry.desktopCommandChainVerified -eq $true
  )
  $entryHostProcess = @($normalizedProcesses | Where-Object { $_.id -eq $entryHostProcessId } | Select-Object -First 1)
  $entryHostProcessStartedAt = if ($entryHostProcess.Count -eq 1) { ConvertTo-SuperBrainCodexHookTimestamp $entryHostProcess[0].startTime } else { $null }
  $entryHostProcessActive = [bool](
    $entryHostProcessId -gt 0 -and
    $entryHostProcess.Count -eq 1 -and
    ([string]$entryHostProcess[0].processName -ieq $entryHostProcessName)
  )
  $entryHostProcessFresh = [bool](
    $entryHostProcessActive -and
    $entryHostProcessStartedAt -and
    $entryHostProcessStartedAt.ToUniversalTime() -ge $evidenceNotBefore.ToUniversalTime()
  )
  $entryDesktopCommandChainValid = [bool](
    $entryDesktopCommandChainVerified -and
    $entryHostProcessSource -eq 'desktop_windows_command_chain' -and
    @('codex-code-mode-host','codex') -contains $entryHostProcessName.ToLowerInvariant() -and
    $entryHostProcessActive -and
    $entryHostProcessFresh
  )
  $stableEntrySeen = [bool](
    $entry -and
    [string]$entry.schema -eq 'super-brain.prompt-hook-handler-entry.v2' -and
    [string]$entry.eventKind -eq 'user_prompt_submit' -and
    [string]$entry.entrypoint -eq 'stable_dispatcher' -and
    $entry.rawPromptStored -eq $false -and
    $entry.rawSessionIdStored -eq $false -and
    $entryObservedAt -and
    $entryDesktopCommandChainValid
  )
  $entryValid = [bool](
    $stableEntrySeen -and
    [string]$entry.generation -eq $HandlerGeneration -and
    [string]$entry.expectedGeneration -eq $HandlerGeneration -and
    $entry.generationMatches -eq $true -and
    [string]$entry.eventKind -eq 'user_prompt_submit' -and
    [string]$entry.entrypoint -eq 'stable_dispatcher' -and
    $entry.rawPromptStored -eq $false -and
    $entry.rawSessionIdStored -eq $false -and
    $entryObservedAt -and
    $entryObservedAt.ToUniversalTime() -ge $evidenceNotBefore.ToUniversalTime()
  )
  $reloadRelevant = @($normalizedProcesses | Where-Object { @('codex','codex-code-mode-host') -contains ([string]$_.processName).ToLowerInvariant() })
  # Handler reinstall can change the stable dispatcher/native generation
  # without changing hooks.json.  Until a current-generation live entry is
  # observed, an app-server/Code Mode Host that predates this install is still
  # allowed to hold the previous cached command/handler.
  $predatingHandlerInstall = @($reloadRelevant | Where-Object { $_.predatesInstall })
  $predatingHookConfig = @($reloadRelevant | Where-Object { $_.predatesHookConfigChange })
  $restartRequired = [bool](-not $entryValid -and ($predatingHookConfig.Count -gt 0 -or $predatingHandlerInstall.Count -gt 0))
  $state = if ($restartRequired) {
    'restart_required'
  } elseif ($entryValid) {
    'validated'
  } elseif ($normalizedProcesses.Count -eq 0) {
    'no_active_host'
  } else {
    'awaiting_real_submit'
  }
  return [pscustomobject]@{
    schema = 'super-brain.codex-hook-host-state.v1'
    state = $state
    checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
    installedAt = $InstalledAt.ToUniversalTime().ToString('o')
    handlerGeneration = $HandlerGeneration
    handlerGenerationValid = ($HandlerGeneration -match '^hg-[a-f0-9]{64}$')
    liveHostValidated = $entryValid
    restartRequired = $restartRequired
    activeProcessCount = $normalizedProcesses.Count
    predatingProcessCount = $predatingHandlerInstall.Count
    hookConfigChangeAt = $hookConfigBoundary.ToUniversalTime().ToString('o')
    evidenceNotBefore = $evidenceNotBefore.ToUniversalTime().ToString('o')
    reloadRelevantProcessCount = $reloadRelevant.Count
    predatingHandlerInstallCount = $predatingHandlerInstall.Count
    predatingHookConfigChangeCount = $predatingHookConfig.Count
    processes = @($normalizedProcesses)
    entryReceiptPath = $EntryReceiptPath
    entryObservedAt = if ($entryObservedAt) { $entryObservedAt.ToUniversalTime().ToString('o') } else { '' }
    entryParentProcessId = $entryParentProcessId
    entryParentActive = $entryParentActive
    entryHostProcessId = $entryHostProcessId
    entryHostProcessName = $entryHostProcessName
    entryHostProcessDepth = $entryHostProcessDepth
    entryHostProcessActive = $entryHostProcessActive
    entryHostProcessStartTime = if ($entryHostProcessStartedAt) { $entryHostProcessStartedAt.ToUniversalTime().ToString('o') } else { '' }
    entryHostProcessFresh = $entryHostProcessFresh
    entryHostProcessSource = $entryHostProcessSource
    entryDesktopCommandChainVerified = $entryDesktopCommandChainVerified
    entryDesktopCommandChainValid = $entryDesktopCommandChainValid
    stableEntrypointSeen = $stableEntrySeen
    rawPromptStored = $false
    rawSessionIdStored = $false
  }
}
