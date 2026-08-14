[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = "$env:USERPROFILE\.codex",
  [switch]$Apply,
  [switch]$NoBackup,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$CodexHome = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CodexHome))
$hooksPath = Join-Path $CodexHome 'hooks.json'
$stableRoot = Join-Path $CodexHome 'hooks\super-memory-brain'
$backups = @()
$removedEvents = @()

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "HOOKLESS_RETIRE_HOOKS_JSON_INVALID path=$Path" }
}

function Write-JsonUtf8([string]$Path,[object]$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 32), [Text.UTF8Encoding]::new($false))
}

function Test-SuperBrainHookCommand([object]$Entry) {
  if ($null -eq $Entry) { return $false }
  # A generic file name such as codex_prompt_hook.py is not enough evidence
  # of ownership: a different Codex integration may use the same name. Retire
  # only entries that identify themselves as Super Brain through their command
  # path or display metadata.
  $identity = @()
  foreach ($name in @('command','commandWindows','statusMessage','name','id','description')) {
    $property = $Entry.PSObject.Properties[$name]
    if ($property) { $identity += [string]$property.Value }
  }
  return (($identity -join [Environment]::NewLine) -match '(?i)super[\s_-]*memory[\s_-]*brain|super\s+brain')
}

function Copy-HookEntryWithChildren([object]$Entry,[object[]]$Children) {
  $copy = [ordered]@{}
  foreach ($property in $Entry.PSObject.Properties) {
    if ($property.Name -eq 'hooks') {
      # Do not build this through an if-expression: its pipeline output turns
      # a one-element child array into a scalar and changes the Hook JSON shape.
      $copy[$property.Name] = [object[]]$Children
    } else {
      $copy[$property.Name] = $property.Value
    }
  }
  return [pscustomobject]$copy
}

function Remove-SuperBrainHookEntries([object[]]$Entries,[string]$EventName) {
  $kept = @()
  $changed = $false
  foreach ($entry in @($Entries)) {
    if (Test-SuperBrainHookCommand $entry) {
      [void]($script:removedEvents += $EventName)
      $changed = $true
      continue
    }
    $children = $entry.PSObject.Properties['hooks']
    if (-not $children) {
      $kept += $entry
      continue
    }
    # Codex hook JSON has one event-group level followed by command entries.
    # Do not recurse through PowerShell's collection adapters: an adapted array
    # can expose the parent's `hooks` property again and never terminate.
    $remainingChildren = @()
    $entryChanged = $false
    foreach ($child in @($children.Value | ForEach-Object { $_ })) {
      if (Test-SuperBrainHookCommand $child) {
        [void]($script:removedEvents += $EventName)
        $entryChanged = $true
        $changed = $true
      } else {
        $remainingChildren += $child
      }
    }
    if (-not $entryChanged) {
      $kept += $entry
      continue
    }
    if (@($remainingChildren).Count -eq 0) {
      continue
    }
    $kept += Copy-HookEntryWithChildren $entry @($remainingChildren)
  }
  return [pscustomobject]@{
    entries = [object[]]$kept
    changed = $changed
  }
}

$document = Read-JsonFile $hooksPath
$configurationChanged = $false
if ($document -and $document.PSObject.Properties['hooks'] -and $document.hooks) {
  foreach ($eventProperty in @($document.hooks.PSObject.Properties)) {
    $before = @($eventProperty.Value | ForEach-Object { $_ })
    $outcome = Remove-SuperBrainHookEntries $before $eventProperty.Name
    $after = [object[]]$outcome.entries
    if ($outcome.changed) {
      $configurationChanged = $true
      if (@($after).Count -eq 0) {
        $document.hooks.PSObject.Properties.Remove($eventProperty.Name)
      } else {
        # Update the existing PSPropertyInfo directly. Add-Member -Force can
        # report success without replacing a ConvertFrom-Json property value.
        $eventProperty.Value = @($after)
      }
    }
  }
}

$artifactPresent = Test-Path -LiteralPath $stableRoot
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ($Apply) {
  if ($configurationChanged) {
    if (-not $NoBackup -and (Test-Path -LiteralPath $hooksPath -PathType Leaf)) {
      $backup = "$hooksPath.bak-super-brain-hookless-$timestamp"
      Copy-Item -LiteralPath $hooksPath -Destination $backup -Force
      $backups += $backup
    }
    Write-JsonUtf8 $hooksPath $document
  }
  if ($artifactPresent) {
    if (-not $NoBackup) {
      $backupRoot = Join-Path $CodexHome 'backups_state\super-brain-hookless'
      New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
      $backup = Join-Path $backupRoot "hooks-super-memory-brain-$timestamp"
      Copy-Item -LiteralPath $stableRoot -Destination $backup -Recurse -Force
      $backups += $backup
    }
    Remove-Item -LiteralPath $stableRoot -Recurse -Force
  }
}

$result = [pscustomobject]@{
  ok = $true
  schema = 'super-brain.hookless-retirement.v1'
  mode = if($Apply){'apply'}else{'report'}
  codexHome = $CodexHome
  hooksPath = $hooksPath
  configurationChanged = $configurationChanged
  removedEventKinds = @($removedEvents | Sort-Object -Unique)
  superBrainArtifactPresent = $artifactPresent
  superBrainArtifactRemoved = [bool]($Apply -and $artifactPresent -and -not (Test-Path -LiteralPath $stableRoot))
  otherHooksPreserved = $true
  backups = @($backups)
  nextAction = if($Apply){'Use brain_turn through the registered Super Brain MCP; no Super Brain Hook remains.'}else{'Review only; rerun with -Apply after H7 runtime verification.'}
}
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "HOOKLESS_RETIRE ok=$($result.ok) mode=$($result.mode) configChanged=$configurationChanged artifacts=$artifactPresent" }
