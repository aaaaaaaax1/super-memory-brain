param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statusPath = Join-Path $workspace 'last-intent-gate.json'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
function Add-Term([string[]]$Terms, [string]$Term) { return @($Terms + @($Term)) }
function Has-Any([string]$Value, [string[]]$Needles) {
  foreach ($needle in @($Needles)) {
    if (-not [string]::IsNullOrWhiteSpace($needle) -and $Value.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  }
  return $false
}

$inputText = (($Text -join ' ').Trim())

$noiseTerms = @('ocr','screenshot','log fragment','button text','raw text','page fragment','no user instruction')
$noiseTerms = Add-Term $noiseTerms (U @(0x622A,0x56FE))
$noiseTerms = Add-Term $noiseTerms (U @(0x65E5,0x5FD7))
$noiseTerms = Add-Term $noiseTerms (U @(0x9875,0x9762,0x7247,0x6BB5))

$planOnlyTerms = @('plan only','proposal only','do not execute','do not modify','do not edit','no changes')
$planOnlyTerms = Add-Term $planOnlyTerms (U @(0x5148,0x51FA,0x65B9,0x6848))
$planOnlyTerms = Add-Term $planOnlyTerms (U @(0x5148,0x8BA1,0x5212))
$planOnlyTerms = Add-Term $planOnlyTerms (U @(0x4E0D,0x8981,0x6267,0x884C))
$planOnlyTerms = Add-Term $planOnlyTerms (U @(0x4E0D,0x8981,0x76F4,0x63A5,0x6539))
$planOnlyTerms = Add-Term $planOnlyTerms (U @(0x5148,0x8BF4,0x600E,0x4E48,0x505A))

$statusTerms = @('task status','current task','progress','what remains','next action')
$statusTerms = Add-Term $statusTerms (U @(0x4EFB,0x52A1,0x72B6,0x6001))
$statusTerms = Add-Term $statusTerms (U @(0x5F53,0x524D,0x4EFB,0x52A1,0x72B6,0x6001))
$statusTerms = Add-Term $statusTerms (U @(0x8FDB,0x5EA6))
$statusTerms = Add-Term $statusTerms (U @(0x5B8C,0x6210,0x591A,0x5C11))
$statusTerms = Add-Term $statusTerms (U @(0x4E0B,0x4E00,0x6B65,0x662F,0x4EC0,0x4E48))
$statusTerms = Add-Term $statusTerms (U @(0x6709,0x54EA,0x4E9B,0x4EFB,0x52A1))
$statusTerms = Add-Term $statusTerms (U @(0x4EFB,0x52A1,0x5217,0x8868))

$executeTerms = @('continue','resume','execute','start','go ahead','do it','implement','apply')
$executeTerms = Add-Term $executeTerms (U @(0x7EE7,0x7EED))
$executeTerms = Add-Term $executeTerms (U @(0x63A5,0x7740,0x505A))
$executeTerms = Add-Term $executeTerms (U @(0x5F00,0x59CB))
$executeTerms = Add-Term $executeTerms (U @(0x6267,0x884C))
$executeTerms = Add-Term $executeTerms (U @(0x6309,0x8FD9,0x4E2A,0x505A))
$executeTerms = Add-Term $executeTerms (U @(0x53EF,0x4EE5,0x6267,0x884C))

$questionTerms = @('?')
$questionTerms = Add-Term $questionTerms ([string][char]0xFF1F)
$questionTerms = Add-Term $questionTerms (U @(0x600E,0x4E48))
$questionTerms = Add-Term $questionTerms (U @(0x662F,0x5426))
$questionTerms = Add-Term $questionTerms (U @(0x80FD,0x4E0D,0x80FD))

$matched = @()
$intent = 'clarify'
$canMutate = $false
$shouldExecute = $false
$shouldAsk = $true
$reason = 'no_clear_intent'

if (Has-Any $inputText $noiseTerms) {
  $intent = 'clarify'
  $canMutate = $false
  $shouldExecute = $false
  $shouldAsk = $false
  $reason = 'evidence_noise_only'
  $matched += 'noise'
} elseif (Has-Any $inputText $planOnlyTerms) {
  $intent = 'plan_only'
  $shouldAsk = $false
  $reason = 'plan_only_terms'
  $matched += 'plan_only'
} elseif (Has-Any $inputText $statusTerms) {
  $intent = 'status_only'
  $shouldAsk = $false
  $reason = 'status_terms'
  $matched += 'status_only'
} elseif (Has-Any $inputText $executeTerms) {
  $intent = 'execute'
  $canMutate = $true
  $shouldExecute = $true
  $shouldAsk = $false
  $reason = 'execute_terms'
  $matched += 'execute'
} elseif (Has-Any $inputText $questionTerms) {
  $intent = 'clarify'
  $shouldAsk = $false
  $reason = 'question_or_sop'
  $matched += 'question'
}

$recommendedResponse = 'Ask one focused clarification or answer without mutation.'
if ($intent -eq 'plan_only') { $recommendedResponse = 'Return problem list, SOP, and acceptance criteria only.' }
elseif ($intent -eq 'status_only') { $recommendedResponse = 'Return current task status/list only.' }
elseif ($intent -eq 'execute') { $recommendedResponse = 'Show tiny resume card, then execute next concrete step.' }

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = [string]$manifest.version
  input = $inputText
  intent = $intent
  canMutate = $canMutate
  shouldExecute = $shouldExecute
  shouldAsk = $shouldAsk
  reason = $reason
  matched = @($matched)
  policy = 'plan_only/status_only cannot mutate; execute can mutate only when user clearly authorizes; clarify asks or answers without mutation.'
  recommendedResponse = $recommendedResponse
  statusPath = $statusPath
}
Write-JsonUtf8NoBom $statusPath $result 8
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "INTENT_GATE intent=$($result.intent) canMutate=$($result.canMutate) reason=$($result.reason) status=$statusPath" }
exit 0
