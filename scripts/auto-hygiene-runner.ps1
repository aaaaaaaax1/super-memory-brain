param(
  [switch]$Json,
  [switch]$ApplySafe,
  [int]$MaxMemoryChars = 0,
  [int]$MaxActions = 20
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$workspace = Join-Path $memoryBase 'workspace'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$outPath = Join-Path $workspace 'last-memory-hygiene.json'
$evidenceRoot = Join-Path $workspace 'compressed-memory-evidence'
if (-not (Test-Path -LiteralPath $evidenceRoot)) { New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null }

$memoryPolicy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($MaxMemoryChars -le 0) { $MaxMemoryChars = [int]$memoryPolicy.maxMemoryChars }
if ($MaxActions -le 0) { $MaxActions = 20 }
$memoryPath = Join-Path $memoryRoot 'sandglass.txt'
$actions = New-Object System.Collections.ArrayList
$errors = New-Object System.Collections.ArrayList
$now = Get-Date
$stamp = $now.ToString('yyyyMMdd-HHmmss')

function Limit-Text([string]$Value, [int]$Max = 260) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '\s+', ' '
  if ($v.Length -gt $Max) { return $v.Substring(0, $Max) + '...' }
  return $v
}

function Test-PrivatePatternHit([string]$Line, [string]$Pattern) {
  $lowerLine = $Line.ToLowerInvariant()
  $lowerPattern = $Pattern.ToLowerInvariant()
  if (-not $lowerLine.Contains($lowerPattern)) { return $false }
  if ($lowerPattern -eq 'token') {
    return ($Line -match '(?i)(access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|bearer\s+[A-Za-z0-9._-]{12,}|token\s*[:=]\s*[A-Za-z0-9._-]{12,})')
  }
  if ($lowerPattern -eq 'secret') {
    return ($Line -match '(?i)(client[_-]?secret|secret\s*[:=]\s*\S{8,}|BEGIN .*PRIVATE KEY)')
  }
  return $true
}

function Get-PrivatePattern([string]$Line) {
  foreach ($pattern in @($memoryPolicy.privatePatterns)) {
    if (Test-PrivatePatternHit $Line ([string]$pattern)) { return [string]$pattern }
  }
  return ''
}

function Get-TagList([string]$Line) {
  return @([regex]::Matches($Line, '\[[A-Z_]+\]') | ForEach-Object { $_.Value } | Select-Object -Unique)
}

function Get-MemoryPrefix([string]$Line) {
  $m = [regex]::Match($Line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| [^|]+ \| )')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function New-CompactLine([string]$Line) {
  $prefix = Get-MemoryPrefix $Line
  $tags = Get-TagList $Line
  if ($tags.Count -eq 0) { $tags = @('[SUMMARY]') }
  $body = $Line
  if (-not [string]::IsNullOrWhiteSpace($prefix) -and $body.StartsWith($prefix)) { $body = $body.Substring($prefix.Length) }
  foreach ($marker in @(' | evidence=', ' | consequences=', ' | alternatives=', ' | source=', ' | raw=', ' | details=')) {
    $idx = $body.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
    if ($idx -gt 0) { $body = $body.Substring(0, $idx); break }
  }
  $tagText = (($tags | Select-Object -First 8) -join '')
  $body = ($body -replace '\s+', ' ').Trim()
  if ($body.Length -gt [Math]::Max(160, $MaxMemoryChars - $prefix.Length - $tagText.Length - 90)) {
    $body = $body.Substring(0, [Math]::Max(160, $MaxMemoryChars - $prefix.Length - $tagText.Length - 90)).Trim() + '...'
  }
  if ($body -notmatch '\[SUMMARY\]') { $body = ($tagText + '[SUMMARY] ' + ($body -replace '\[[A-Z_]+\]', '').Trim()).Trim() }
  $result = ($prefix + $body).Trim()
  if ($result.Length -gt $MaxMemoryChars) { $result = $result.Substring(0, $MaxMemoryChars - 3).TrimEnd() + '...' }
  return $result
}

function Add-Action([string]$Type, [int]$LineNumber, [string]$Action, [string]$Reason, [string]$Before, [string]$After = '', [bool]$Applied = $false, [string]$Risk = 'low') {
  [void]$script:actions.Add([pscustomobject]@{
    type = $Type
    line = $LineNumber
    action = $Action
    reason = Limit-Text $Reason 420
    risk = $Risk
    applied = $Applied
    beforeChars = if ($Before) { $Before.Length } else { 0 }
    afterChars = if ($After) { $After.Length } else { 0 }
    preview = Limit-Text $Before 180
  })
}
function Add-Error([string]$Where, [string]$Message) { [void]$script:errors.Add([pscustomobject]@{ where=$Where; message=Limit-Text $Message 500 }) }

$beforeHealth = $null
try { $beforeHealth = (& (Join-Path $PSScriptRoot 'memory-health.ps1') -Json | ConvertFrom-Json) } catch {}

$archivePath = Join-Path $evidenceRoot ('memory-hygiene-' + $stamp + '.json')
$originalLines = @()
$newLines = @()
$archiveItems = New-Object System.Collections.ArrayList
$seen = @{}
$lineNumber = 0
$changed = $false

if (Test-Path -LiteralPath $memoryPath) {
  $originalLines = @(Get-Content -LiteralPath $memoryPath -Encoding UTF8)
  foreach ($line in $originalLines) {
    $lineNumber += 1
    if ([string]::IsNullOrWhiteSpace($line)) { $newLines += $line; continue }
    $current = [string]$line
    $privatePattern = Get-PrivatePattern $current
    if (-not [string]::IsNullOrWhiteSpace($privatePattern)) {
      if ($actions.Count -lt $MaxActions) { Add-Action 'private_pattern' $lineNumber 'requires_confirmation' ('private-pattern hit: ' + $privatePattern) $current '' $false 'high' }
      $newLines += $current
      continue
    }

    $key = $current -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| [^|]+ \| ', ''
    if ($seen.ContainsKey($key)) {
      if ($actions.Count -lt $MaxActions) {
        Add-Action 'duplicate' $lineNumber 'remove_duplicate_with_archive' 'Exact duplicate after timestamp/source normalization.' $current '' $ApplySafe 'low'
      }
      if ($ApplySafe) {
        [void]$archiveItems.Add([pscustomobject]@{ line=$lineNumber; type='duplicate'; original=$current })
        $changed = $true
        continue
      }
    } else {
      $seen[$key] = $true
    }

    if ($current.Length -gt $MaxMemoryChars) {
      $compact = New-CompactLine $current
      if ($actions.Count -lt $MaxActions) { Add-Action 'too_long' $lineNumber 'compress_with_original_archive' ('chars ' + $current.Length + ' > ' + $MaxMemoryChars) $current $compact $ApplySafe 'low' }
      if ($ApplySafe -and $compact -ne $current) {
        [void]$archiveItems.Add([pscustomobject]@{ line=$lineNumber; type='too_long'; original=$current; compact=$compact })
        $newLines += $compact
        $changed = $true
        continue
      }
    }
    $newLines += $current
  }
}

if ($ApplySafe -and $changed) {
  try {
    $archive = [pscustomobject]@{
      schema = 'super-brain.memory-hygiene-evidence.v1'
      version = [string]$manifest.version
      archivedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      memoryPath = $memoryPath
      maxMemoryChars = $MaxMemoryChars
      originalLineCount = $originalLines.Count
      archivedItemCount = $archiveItems.Count
      actions = @($actions)
      archivedItems = @($archiveItems)
    }
    Write-JsonUtf8NoBom $archivePath $archive 16
    Write-Utf8NoBom $memoryPath (($newLines -join "`n") + "`n")
  } catch { Add-Error 'memory_write' $_.Exception.Message }
}

$afterHealth = $null
try { $afterHealth = (& (Join-Path $PSScriptRoot 'memory-health.ps1') -Json | ConvertFrom-Json) } catch {}

$result = [pscustomobject]@{
  ok = ($errors.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.auto-hygiene.v1'
  version = [string]$manifest.version
  mode = if ($ApplySafe) { 'ApplySafe' } else { 'Plan' }
  memory = $memoryPath
  archivePath = if ($ApplySafe -and $changed) { $archivePath } else { '' }
  maxMemoryChars = $MaxMemoryChars
  before = if ($beforeHealth) { [pscustomobject]@{ duplicateCount=$beforeHealth.duplicateCount; tooLongCount=$beforeHealth.tooLongCount; privatePatternHitCount=$beforeHealth.privatePatternHitCount; invalidExpiryCount=$beforeHealth.invalidExpiryCount } } else { $null }
  after = if ($afterHealth) { [pscustomobject]@{ duplicateCount=$afterHealth.duplicateCount; tooLongCount=$afterHealth.tooLongCount; privatePatternHitCount=$afterHealth.privatePatternHitCount; invalidExpiryCount=$afterHealth.invalidExpiryCount } } else { $null }
  actionCount = $actions.Count
  appliedCount = @($actions | Where-Object { $_.applied -eq $true }).Count
  requiresConfirmation = @($actions | Where-Object { $_.action -eq 'requires_confirmation' }).Count
  changed = [bool]($ApplySafe -and $changed)
  actions = @($actions)
  errors = @($errors)
  policy = [pscustomobject]@{
    lowRiskCompression = 'archive_original_then_replace_with_summary'
    duplicateCleanup = 'archive_original_then_remove_duplicate'
    privatePatternHits = 'confirmation_required'
    noRawPrivateInReport = $true
  }
}
Write-JsonUtf8NoBom $outPath $result 14
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else {
  Write-Host "AUTO_HYGIENE ok=$($result.ok) mode=$($result.mode) actions=$($result.actionCount) applied=$($result.appliedCount) requiresConfirmation=$($result.requiresConfirmation) changed=$($result.changed) path=$outPath"
}
if ($errors.Count -gt 0) { exit 1 }
if ($result.requiresConfirmation -gt 0 -and -not $ApplySafe) { exit 0 }
exit 0
