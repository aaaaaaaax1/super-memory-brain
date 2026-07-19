function Get-TeamTaskStateRoot([string]$Root,[string]$StateRoot) {
  if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
    return [IO.Path]::GetFullPath($StateRoot)
  }
  return Get-SuperBrainMemoryBaseRoot $Root
}

function Get-TeamTaskWorkspace([string]$Root,[string]$StateRoot) {
  return Join-Path (Get-TeamTaskStateRoot $Root $StateRoot) 'workspace'
}

function New-TeamTaskIdentity([string]$Prefix) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
  return "$Prefix-$stamp-$([guid]::NewGuid().ToString('N'))"
}

function Read-TeamTaskRecord([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Team task not found: $([IO.Path]::GetFileNameWithoutExtension($Path))" }
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-TeamTaskRecordUnlocked([string]$Path,[object]$Value,[int]$Depth=14) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $temporaryPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.tmp.' + $PID + '.' + [guid]::NewGuid().ToString('N'))
  try {
    [IO.File]::WriteAllText($temporaryPath,($Value | ConvertTo-Json -Depth $Depth),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
  } finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-TeamTaskRecordLock([string]$Path,[scriptblock]$Body) {
  return Invoke-SuperBrainFileLock $Path $Body
}

function Update-TeamTaskIndex([string]$ScriptRoot,[string]$StateRoot) {
  $parameters = @{ Json = $true }
  if (-not [string]::IsNullOrWhiteSpace($StateRoot)) { $parameters.StateRoot = $StateRoot }
  $result = & (Join-Path $ScriptRoot 'team-task-index.ps1') @parameters
  if ($LASTEXITCODE -ne 0) { throw 'TEAM_TASK_INDEX_UPDATE_FAILED' }
  return $result
}

function Test-TeamTaskTerminalDelegationStatus([string]$Status) {
  return $Status -in @('reported','blocked','rejected')
}

function Get-TeamTaskReportFingerprint([object]$Value) {
  $json = $Value | ConvertTo-Json -Depth 12 -Compress
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)) | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha.Dispose()
  }
}

function ConvertTo-TeamTaskJoinSlots([string[]]$SlotIds) {
  $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $slots = @()
  foreach ($value in @($SlotIds)) {
    foreach ($candidate in ([string]$value -split ',')) {
      $slotId = $candidate.Trim()
      if ([string]::IsNullOrWhiteSpace($slotId)) { continue }
      if ($slotId.Length -gt 120 -or $slotId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "TEAM_TASK_JOIN_SLOT_INVALID: $slotId"
      }
      if (-not $seen.Add($slotId)) { throw "TEAM_TASK_JOIN_SLOT_DUPLICATE: $slotId" }
      $slots += [pscustomobject]@{
        slotId = $slotId
        status = 'pending'
        delegationId = ''
        reportedAt = ''
        terminalAt = ''
      }
    }
  }
  return @($slots)
}

function Get-TeamTaskJoinStatus(
  [object]$Record,
  [string[]]$IntegratedJoinSlots = @(),
  [string[]]$IntegratedDelegationIds = @()
) {
  $expectedSlots = @(if ($Record -and $Record.PSObject.Properties['expectedJoinSlots']) { @($Record.expectedJoinSlots) } else { @() })
  $requiresJoin = ([string]$Record.dispatchLevel -eq 'team_parallel' -or $expectedSlots.Count -gt 0)
  $integratedSlotSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $integratedDelegationSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($slotId in @($IntegratedJoinSlots)) {
    foreach ($candidate in ([string]$slotId -split ',')) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) { [void]$integratedSlotSet.Add($candidate.Trim()) }
    }
  }
  foreach ($delegationId in @($IntegratedDelegationIds)) {
    foreach ($candidate in ([string]$delegationId -split ',')) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) { [void]$integratedDelegationSet.Add($candidate.Trim()) }
    }
  }

  $blockers = @()
  $pendingSlots = @()
  $unintegratedSlots = @()
  $terminalSlotIds = @()
  $resolvedIntegratedSlots = @()
  if ($requiresJoin -and $expectedSlots.Count -eq 0) { $blockers += 'expected_join_slots_missing' }

  foreach ($slot in $expectedSlots) {
    $slotId = [string]$slot.slotId
    if ([string]::IsNullOrWhiteSpace($slotId)) {
      $blockers += 'expected_join_slot_invalid'
      continue
    }
    $delegationId = if ($slot.PSObject.Properties['delegationId']) { [string]$slot.delegationId } else { '' }
    if ([string]::IsNullOrWhiteSpace($delegationId)) {
      $pendingSlots += $slotId
      $blockers += "expected_join_slot_pending:$slotId"
      continue
    }
    $delegation = @($Record.delegations | Where-Object { $_ -and $_.PSObject.Properties['delegationId'] -and [string]$_.delegationId -eq $delegationId } | Select-Object -First 1)[0]
    if (-not $delegation) {
      $pendingSlots += $slotId
      $blockers += "expected_join_slot_report_missing:$slotId"
      continue
    }
    if (-not (Test-TeamTaskTerminalDelegationStatus ([string]$delegation.status))) {
      $pendingSlots += $slotId
      $blockers += "expected_join_slot_pending:$slotId"
      continue
    }
    $terminalSlotIds += $slotId
    if ($integratedSlotSet.Contains($slotId) -or $integratedDelegationSet.Contains($delegationId)) {
      $resolvedIntegratedSlots += $slotId
    } else {
      $unintegratedSlots += $slotId
      $blockers += "expected_join_slot_not_integrated:$slotId"
    }
  }

  return [pscustomobject]@{
    ok = ($blockers.Count -eq 0)
    required = $requiresJoin
    expectedSlotCount = $expectedSlots.Count
    terminalSlotCount = $terminalSlotIds.Count
    integratedSlotCount = $resolvedIntegratedSlots.Count
    terminalSlotIds = @($terminalSlotIds)
    integratedSlotIds = @($resolvedIntegratedSlots)
    pendingSlotIds = @($pendingSlots)
    unintegratedSlotIds = @($unintegratedSlots)
    blockers = @($blockers)
  }
}
