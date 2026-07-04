param(
  [Parameter(Mandatory=$true)]
  [string]$Question,
  [Parameter(Mandatory=$true)]
  [string]$Decision,
  [string]$Sender = 'user',
  [string]$Key = '',
  [string]$Supersedes = '',
  [string]$Evidence = 'write-decision.ps1',
  [switch]$Adr,
  [string]$Title = '',
  [ValidateSet('proposed','accepted','deprecated','superseded','rejected')]
  [string]$Status = 'accepted',
  [string]$Context = '',
  [string]$Consequences = '',
  [string[]]$Alternatives = @(),
  [string]$Owner = '',
  [string]$Scope = '',
  [string[]]$Tags = @(),
  [switch]$NoGraph
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$MemoryScripts = Join-Path $MemoryRoot 'scripts'
$Graph = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'graph.jsonl'
Assert-SuperBrainMemoryWriteAllowed $Root $MemoryRoot 'write-decision'

function Get-DecisionKey([string]$Text) {
  $normalized = $Text.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+', '-'
  $normalized = $normalized.Trim('-')
  if ($normalized.Length -gt 48) { $normalized = $normalized.Substring(0, 48).Trim('-') }
  if (-not [string]::IsNullOrWhiteSpace($normalized)) { return $normalized }

  $sha = [System.Security.Cryptography.SHA1]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    return 'sha1-' + ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 12)
  } finally {
    $sha.Dispose()
  }
}

function Get-DecisionSubject([string]$DecisionKey) {
  if ($DecisionKey.StartsWith('decision:')) { return $DecisionKey }
  return "decision:$DecisionKey"
}

function Join-DecisionTags([string[]]$BaseTags, [string[]]$ExtraTags) {
  $allTags = @()
  foreach ($tag in @($BaseTags + $ExtraTags)) {
    if ([string]::IsNullOrWhiteSpace($tag)) { continue }
    $normalized = [string]$tag
    if (-not $normalized.StartsWith('[')) { $normalized = '[' + $normalized.Trim('[',']').ToUpperInvariant() + ']' }
    if ($allTags -notcontains $normalized) { $allTags += $normalized }
  }
  return ($allTags -join '')
}

function Add-GraphRecord([string]$Subject, [string]$Relation, [string]$Object, [string]$RecordEvidence, [string]$RecordTags) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Graph) | Out-Null
  $record = [ordered]@{
    time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    subject = $Subject
    relation = $Relation
    object = $Object
    evidence = $RecordEvidence
    tags = $RecordTags
  }
  Add-Utf8LineLocked $Graph ($record | ConvertTo-Json -Compress)
}

function Add-GraphIfValue([string]$Subject, [string]$Relation, [string]$Object, [string]$RecordEvidence, [string]$RecordTags) {
  if ([string]::IsNullOrWhiteSpace($Object)) { return }
  Add-GraphRecord $Subject $Relation $Object $RecordEvidence $RecordTags
}

if ([string]::IsNullOrWhiteSpace($Key)) {
  $Key = Get-DecisionKey $Question
} else {
  $Key = Get-DecisionKey $Key
}

$hasAdrFields = ($Adr -or -not [string]::IsNullOrWhiteSpace($Title) -or -not [string]::IsNullOrWhiteSpace($Context) -or -not [string]::IsNullOrWhiteSpace($Consequences) -or @($Alternatives).Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($Owner) -or -not [string]::IsNullOrWhiteSpace($Scope))
if ($hasAdrFields -and [string]::IsNullOrWhiteSpace($Title)) { $Title = $Question }

$currentStatuses = @('proposed','accepted')
$stateTags = if ($currentStatuses -contains $Status) { @('[CURRENT]','[VERIFIED]') } else { @('[STALE]','[VERIFIED]') }
$baseTags = if ($hasAdrFields) { @('[DECISION]','[ADR]') + $stateTags } else { @('[DECISION]','[CURRENT]','[VERIFIED]') }
$graphTags = Join-DecisionTags $baseTags $Tags
$subject = Get-DecisionSubject $Key
$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts

$q64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Question))
$d64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Decision))
$pythonDecisionCode = "import base64; from decision_particles import log; q=base64.b64decode('$q64').decode('utf-8'); d=base64.b64decode('$d64').decode('utf-8'); log(q, d); print('DECISION_PARTICLE_OK')"
python -c $pythonDecisionCode
if ($LASTEXITCODE -ne 0) { throw 'decision_particles.log failed' }

if ($hasAdrFields) {
  $summaryParts = @("[DECISION][ADR]", "key=$Key", "status=$Status", "title=$Title", "decision=$Decision")
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $summaryParts += "scope=$Scope" }
  if (-not [string]::IsNullOrWhiteSpace($Context)) { $summaryParts += "context=$Context" }
  if (-not [string]::IsNullOrWhiteSpace($Consequences)) { $summaryParts += "consequences=$Consequences" }
  if ($currentStatuses -contains $Status) { $summaryParts = @('[CURRENT]','[VERIFIED]') + $summaryParts } else { $summaryParts = @('[STALE]','[VERIFIED]') + $summaryParts }
  $text = ($summaryParts -join ' ')
} else {
  $text = "[DECISION][CURRENT][VERIFIED] key=$Key $Question => $Decision"
}

$t64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text))
$s64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Sender))
$pythonMemoryCode = "import base64; from sandglass_log import log_message; text=base64.b64decode('$t64').decode('utf-8'); sender=base64.b64decode('$s64').decode('utf-8'); print(log_message(text, sender))"
python -c $pythonMemoryCode
if ($LASTEXITCODE -ne 0) { throw 'sandglass_log.log_message failed' }

if (-not $NoGraph) {
  Add-GraphRecord $subject 'decides' $Decision $Evidence $graphTags
  if ($hasAdrFields) {
    Add-GraphIfValue $subject 'has_title' $Title $Evidence $graphTags
    Add-GraphIfValue $subject 'has_status' $Status $Evidence $graphTags
    Add-GraphIfValue $subject 'has_context' $Context $Evidence $graphTags
    Add-GraphIfValue $subject 'has_consequence' $Consequences $Evidence $graphTags
    Add-GraphIfValue $subject 'has_owner' $Owner $Evidence $graphTags
    Add-GraphIfValue $subject 'affects' $Scope $Evidence $graphTags
    foreach ($alternative in @($Alternatives)) {
      Add-GraphIfValue $subject 'has_alternative' $alternative $Evidence $graphTags
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($Supersedes)) {
    $oldKey = Get-DecisionKey $Supersedes
    $oldSubject = Get-DecisionSubject $oldKey
    Add-GraphRecord $subject 'supersedes' $oldSubject $Evidence $graphTags
    $staleTags = @('[DECISION]','[STALE]','[VERIFIED]')
    if ($hasAdrFields) { $staleTags += '[ADR]' }
    Add-GraphRecord $oldSubject 'superseded_by' $subject $Evidence (Join-DecisionTags $staleTags @())
  }
}

Write-Host "DECISION_WRITE_OK key=$Key subject=$subject adr=$hasAdrFields status=$Status graph=$(-not $NoGraph)"
