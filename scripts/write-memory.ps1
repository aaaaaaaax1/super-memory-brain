param(
  [Parameter(Mandatory=$true)]
  [string]$Text,
  [string]$Sender = 'user',
  [ValidateSet('auto','force','off')]
  [string]$MemoryMode = 'auto',
  [ValidateSet('','profile','project','decision','task','session')]
  [string]$Layer = '',
  [switch]$Summary,
  [datetime]$ExpiresAt,
  [switch]$Force,
  [switch]$ConfirmPrivate
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$MemoryScripts = Join-Path $MemoryRoot 'scripts'
$PolicyPath = Join-Path $Root 'memory-policy.json'
$Policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-SuperBrainMemoryWriteAllowed $Root $MemoryRoot 'write-memory'

if ($MemoryMode -eq 'off') {
  Write-Host 'MEMORY_OFF: write skipped by memory mode.'
  exit 0
}
if ($MemoryMode -eq 'force') { $Force = $true }

$score = 0
$lower = $Text.ToLowerInvariant()
$privateHits = @()
$profileIntentPatterns = @($Policy.writeAllowSignals | Where-Object {
  ($_ -like '*偏好*') -or
  ($_ -like '*性格*') -or
  ($_ -like '*经历*') -or
  ($_ -like '*习惯*') -or
  ($_ -like '*喜欢*') -or
  ($_ -like '*通常*') -or
  ($_ -like '*风格*')
})
$profileIntentPatterns += @('still remember me','my preferences','my personality','my experience','my style','how i usually work')
$profileIntentMatched = $false
foreach ($pattern in @($profileIntentPatterns | Select-Object -Unique)) {
  if (-not [string]::IsNullOrWhiteSpace([string]$pattern) -and ($Text.IndexOf([string]$pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) { $profileIntentMatched = $true; break }
}
if ([string]::IsNullOrWhiteSpace($Layer) -and $profileIntentMatched) { $Layer = 'profile' }
if ($profileIntentMatched) { $score += 2 }

foreach ($pattern in $Policy.privatePatterns) {
  if ($lower.Contains($pattern.ToLowerInvariant())) {
    $privateHits += $pattern
  }
}

if ($privateHits.Count -gt 0 -and -not $ConfirmPrivate -and -not $Force) {
  Write-Host 'NEEDS_CONFIRMATION: possible private memory detected.'
  Write-Host ('Matched: ' + ($privateHits -join ', '))
  Write-Host 'If the user confirms this is their memory and should be stored, rerun with -ConfirmPrivate. It will be stored with [PRIVACY].'
  exit 2
}

foreach ($signal in $Policy.writeAllowSignals) {
  if ($Text.Contains($signal)) { $score += 1 }
}

if (-not [string]::IsNullOrWhiteSpace($Layer)) {
  $tag = $Policy.layers.tagMap.$Layer
  if ($tag -and -not $Text.Contains($tag)) { $Text = "$tag $Text" }
}
if ($Summary -and -not $Text.Contains('[SUMMARY]')) { $Text = "[SUMMARY] $Text" }
if ($PSBoundParameters.ContainsKey('ExpiresAt') -and $Text -notmatch 'expires=\d{4}-\d{2}-\d{2}') {
  $Text = "$Text expires=$($ExpiresAt.ToString('yyyy-MM-dd'))"
}

$negativeHit = $false
foreach ($pattern in @($Policy.feedback.negativePatterns)) {
  if ($Text.Contains($pattern)) { $negativeHit = $true; break }
}
if ($negativeHit -and -not $Text.Contains($Policy.feedback.negativeTag)) {
  $Text = "$($Policy.feedback.negativeTag) $Text"
  $score += 2
}

if ($Text -match '\[CURRENT\]|\[VERIFIED\]|\[DECISION\]|\[BLOCKER\]|\[PROFILE\]|\[PROJECT\]|\[TASK\]|\[SESSION\]|\[SUMMARY\]|\[NEGATIVE_FEEDBACK\]') { $score += 2 }
if ($Text -match 'verified|验证|baseline|基线|决策|decision|rollback|回滚') { $score += 2 }
if ($Text.Length -gt [int]$Policy.maxMemoryChars) { $score -= 2 }
if ($Text -match '^(好的|收到|明白|可以|嗯|OK|ok)$') { $score -= 3 }

if ($privateHits.Count -gt 0 -and $ConfirmPrivate -and $Text -notmatch '\[PRIVACY\]') {
  $Text = "[PRIVACY] $Text"
}

$hasTag = $false
foreach ($tag in $Policy.requiredTags) {
  if ($Text.Contains($tag)) { $hasTag = $true; break }
}

if (-not $Force) {
  if (-not $hasTag) {
    Write-Host 'DENY: memory needs a governance/layer tag like [CURRENT], [VERIFIED], [PROJECT], [SUMMARY], [DECISION], [BLOCKER], [KNOWN_LIMITATION], or [PRIVACY]. Use -Force to override.'
    exit 3
  }
  if ($score -lt [int]$Policy.admissionThreshold -and -not $ConfirmPrivate) {
    Write-Host "DENY: admission score $score is below threshold $($Policy.admissionThreshold). Use -Force to override."
    exit 4
  }
}

$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts
$bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
$b64 = [Convert]::ToBase64String($bytes)
$sender64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Sender))
python -c "import base64; from sandglass_log import log_message; text=base64.b64decode('$b64').decode('utf-8'); sender=base64.b64decode('$sender64').decode('utf-8'); print(log_message(text, sender))"
Write-Host "WRITE_OK score=$score private=$($privateHits.Count -gt 0) negative=$negativeHit layer=$Layer summary=$Summary memory=$MemoryRoot"
