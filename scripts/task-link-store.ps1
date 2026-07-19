function Get-SuperBrainTaskLinkPolicy([string]$Root) {
  $defaults = [pscustomobject]@{
    maxSessionTaskLinks = 256
    maxTaskMemoryLinks = 512
    completedRetentionDays = 120
  }
  try {
    $policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $configured = $policy.taskIdentityIndex
    if ($configured) {
      foreach ($name in @('maxSessionTaskLinks','maxTaskMemoryLinks','completedRetentionDays')) {
        if ($configured.PSObject.Properties[$name] -and [int]$configured.$name -gt 0) { $defaults.$name = [int]$configured.$name }
      }
    }
  } catch {}
  return $defaults
}

function Get-SuperBrainLinkValue([object]$Link,[string]$Name) {
  if (-not $Link) { return '' }
  $property = $Link.PSObject.Properties[$Name]
  if (-not $property) { return '' }
  return [string]$property.Value
}

function Get-SuperBrainTaskLinkKey([object]$Link,[ValidateSet('session-task','task-memory')][string]$Kind) {
  $parts = if ($Kind -eq 'session-task') {
    @('platform','agentId','sessionId','taskId')
  } else {
    @('taskId','memoryId','agentId','sessionId')
  }
  $values = @($parts | ForEach-Object { (Get-SuperBrainLinkValue $Link $_).Trim().ToLowerInvariant() })
  if ([string]::IsNullOrWhiteSpace((Get-SuperBrainLinkValue $Link 'taskId'))) { return '' }
  if ($Kind -eq 'task-memory' -and [string]::IsNullOrWhiteSpace((Get-SuperBrainLinkValue $Link 'memoryId'))) { return '' }
  return ($values -join '|')
}

function Get-SuperBrainLinkDate([object]$Link) {
  $value = Get-SuperBrainLinkValue $Link 'updatedAt'
  if ([string]::IsNullOrWhiteSpace($value)) { return [datetime]::MinValue }
  try { return [datetime]::Parse($value) } catch { return [datetime]::MinValue }
}

function Merge-SuperBrainTaskLinks(
  [object[]]$Existing,
  [object[]]$Incoming,
  [ValidateSet('session-task','task-memory')][string]$Kind,
  [int]$MaxItems,
  [int]$CompletedRetentionDays
) {
  $byKey = @{}
  foreach ($link in @($Existing) + @($Incoming)) {
    $key = Get-SuperBrainTaskLinkKey $link $Kind
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    if (-not $byKey.ContainsKey($key) -or (Get-SuperBrainLinkDate $link) -ge (Get-SuperBrainLinkDate $byKey[$key])) { $byKey[$key] = $link }
  }

  $ordered = @($byKey.Values | Sort-Object @{Expression={Get-SuperBrainLinkDate $_};Descending=$true},taskId,memoryId)
  if ($Kind -eq 'task-memory') { return @($ordered | Select-Object -First $MaxItems) }

  $activeStatuses = @('active','running','in_progress','paused','waiting','blocked')
  $cutoff = (Get-Date).AddDays(-1 * $CompletedRetentionDays)
  $active = @($ordered | Where-Object { $activeStatuses -contains (Get-SuperBrainLinkValue $_ 'status').ToLowerInvariant() })
  $history = @($ordered | Where-Object {
    $status = (Get-SuperBrainLinkValue $_ 'status').ToLowerInvariant()
    if ($activeStatuses -contains $status) { return $false }
    $date = Get-SuperBrainLinkDate $_
    return ($date -eq [datetime]::MinValue -or $date -ge $cutoff)
  })
  $remaining = [Math]::Max(0,$MaxItems - $active.Count)
  return @($active + @($history | Select-Object -First $remaining))
}

function Update-SuperBrainTaskLinkFile(
  [string]$Path,
  [string]$Schema,
  [ValidateSet('session-task','task-memory')][string]$Kind,
  [object[]]$Incoming,
  [int]$MaxItems,
  [int]$CompletedRetentionDays,
  [string]$UpdatedAt
) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $result = Invoke-SuperBrainFileLock $Path {
    $existing = @()
    if (Test-Path -LiteralPath $Path) {
      try {
        $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($document -and $document.links) { $existing = @($document.links) }
      } catch {}
    }
    $links = @(Merge-SuperBrainTaskLinks -Existing $existing -Incoming $Incoming -Kind $Kind -MaxItems $MaxItems -CompletedRetentionDays $CompletedRetentionDays)
    $document = [pscustomobject]@{
      schema = $Schema
      updatedAt = $UpdatedAt
      identity = if ($Kind -eq 'session-task') { 'platform|agentId|sessionId|taskId' } else { 'taskId|memoryId|agentId|sessionId' }
      maxItems = $MaxItems
      retentionDays = if ($Kind -eq 'session-task') { $CompletedRetentionDays } else { $null }
      links = $links
    }
    $temp = "$Path.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
      [IO.File]::WriteAllText($temp,($document | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
      Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
      if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{ path=$Path; beforeCount=$existing.Count; afterCount=$links.Count; prunedCount=[Math]::Max(0,($existing.Count + @($Incoming).Count) - $links.Count); links=$links }
  }
  return $result
}
