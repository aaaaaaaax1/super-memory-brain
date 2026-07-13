param(
  [switch]$Refresh,
  [int]$MaxTokens = 180,
  [int]$TopK = 3,
  [string]$PreferredQuery = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$cardPath = Join-Path $workspace 'profile-card.json'

if (-not $Refresh -and [string]::IsNullOrWhiteSpace($PreferredQuery) -and (Test-Path $cardPath)) {
  if ($Json) { Get-Content -LiteralPath $cardPath -Raw -Encoding UTF8 } else { Write-Host "PROFILE_CARD_OK path=$cardPath cached=True" }
  exit 0
}

$recall = @()
foreach ($query in @($PreferredQuery,'profile preference') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique) {
  try {
    $recallOutput = @(& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query $query -TopK $TopK -MaxTokens ([Math]::Max(160, $MaxTokens)) -Layer profile -MemoryMode auto -Json 2>&1)
    $parsedRecall = (($recallOutput -join "`n") | ConvertFrom-Json)
    foreach ($item in @($parsedRecall)) {
      $key = if($item.evidenceCard){[string]$item.evidenceCard.claim}else{[string]$item.text}
      if (@($recall | Where-Object { $existingKey=if($_.evidenceCard){[string]$_.evidenceCard.claim}else{[string]$_.text}; $existingKey -eq $key }).Count -eq 0) { $recall += $item }
    }
  } catch {}
}

$cards = @($recall | Select-Object -First $TopK | ForEach-Object {
  if ($_.evidenceCard) { $_.evidenceCard } else { $_ }
})
$claims = @($cards | ForEach-Object {
  $claim = if ($_.claim) { [string]$_.claim } elseif ($_.snippet) { [string]$_.snippet } else { [string]$_ }
  ($claim -replace '\s+', ' ').Trim()
} | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

$budgetChars = [Math]::Max(80, $MaxTokens * 4)
$summary = (($claims | Select-Object -First 3) -join ' | ')
if ($summary.Length -gt $budgetChars) { $summary = $summary.Substring(0, $budgetChars) + '...' }
if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'No stable profile memory found yet.' }

$card = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  tokenBudget = $MaxTokens
  source = 'profile-card.ps1'
  profileSummary = $summary
  evidenceCards = @($cards)
  nextAction = 'Inject profileSummary only when user asks about preferences/persona or says to work by their habits.'
}
Write-JsonUtf8NoBom $cardPath $card 10

if ($Json) {
  Get-Content -LiteralPath $cardPath -Raw -Encoding UTF8
} else {
  Write-Host "PROFILE_CARD_OK path=$cardPath cards=$(@($cards).Count)"
}
