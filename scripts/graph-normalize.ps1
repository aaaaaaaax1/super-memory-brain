param(
  [switch]$Fix
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$current = 'v' + $manifest.version
$graphPath = Join-Path $Root 'memory\graph.jsonl'
if (-not (Test-Path $graphPath)) {
  throw "Missing graph: $graphPath"
}

$lines = @(Get-Content -LiteralPath $graphPath -Encoding UTF8)
$out = @()
$currentCount = 0
$changed = $false
$decisionEntries = @()
$lineNumber = 0

foreach ($line in $lines) {
  $lineNumber += 1
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  try {
    $node = $line | ConvertFrom-Json
  } catch {
    $out += $line
    continue
  }

  if ($node.subject -like 'v[0-9]*') {
    if ($node.subject -eq $current) {
      if ($node.tags -ne '[CURRENT][VERIFIED]') {
        $node.tags = '[CURRENT][VERIFIED]'
        $changed = $true
      }
      $currentCount += 1
    } elseif ($node.tags -like '*[CURRENT]*') {
      $node.tags = ($node.tags -replace '\[CURRENT\]', '[HISTORY]')
      $changed = $true
    }
  }

  if (([string]$node.subject).StartsWith('decision:') -and ([string]$node.relation) -eq 'decides' -and ([string]$node.tags).Contains('[CURRENT]')) {
    $decisionEntries += [pscustomobject]@{ line = $lineNumber; node = $node }
  }

  $out += ($node | ConvertTo-Json -Compress)
}

if ($currentCount -eq 0) {
  $entry = [pscustomobject]@{
    time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    subject = $current
    relation = 'supersedes'
    object = 'UNKNOWN'
    evidence = 'manifest.json'
    tags = '[CURRENT][VERIFIED]'
  }
  $out += ($entry | ConvertTo-Json -Compress)
  $currentCount = 1
  $changed = $true
}

$staleCurrent = @($out | Where-Object { $_ -match '"subject":"v[0-9]' -and $_ -match '\[CURRENT\]' -and $_ -notmatch '"subject":"' + [regex]::Escape($current) + '"' })
if ($staleCurrent.Count -gt 0) { $changed = $true }

$decisionCurrentConflicts = @($decisionEntries | Group-Object { $_.node.subject } | Where-Object { $_.Count -gt 1 })
if ($decisionCurrentConflicts.Count -gt 0) { $changed = $true }

if ($Fix -and $changed) {
  $backup = "$graphPath.bak-normalize-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item -LiteralPath $graphPath -Destination $backup -Force
  Set-Content -LiteralPath $graphPath -Value $out -Encoding UTF8
  Write-Host "GRAPH_NORMALIZE_FIXED current=$current backup=$backup decisionCurrentConflicts=$($decisionCurrentConflicts.Count)"
  exit 0
}

if ($staleCurrent.Count -eq 0 -and $currentCount -gt 0 -and $decisionCurrentConflicts.Count -eq 0) {
  Write-Host "GRAPH_NORMALIZE_OK current=$current decisionCurrentConflicts=0"
  exit 0
}

Write-Host "GRAPH_NORMALIZE_NEEDED current=$current staleCurrent=$($staleCurrent.Count) currentCount=$currentCount decisionCurrentConflicts=$($decisionCurrentConflicts.Count)"
exit 1
