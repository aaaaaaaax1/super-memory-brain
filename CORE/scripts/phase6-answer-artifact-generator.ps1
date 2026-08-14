[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Status','Preflight','Probe','Generate','ExportNative','ImportNative')]
  [string]$Action = 'Status',
  [string]$AnswerInputPath = '',
  [string]$OutputPath = '',
  [string]$Model = 'gpt-5.6-terra',
  [ValidateSet('low','medium','high','xhigh','max')]
  [string]$ReasoningEffort = 'max',
  [string]$ResponsesUrl = '',
  [string]$ApiKeyEnv = 'SUPER_BRAIN_ANSWER_API_KEY',
  [ValidateRange(5,300)]
  [int]$TimeoutSeconds = 300,
  [ValidateRange(1,3)]
  [int]$ProbeMaxAttempts = 3,
  [ValidateRange(0,10000)]
  [int]$ProbeRetryDelayMilliseconds = 750,
  [ValidateRange(1,1)]
  [int]$MaxBatchAttempts = 1,
  [ValidateRange(1,20)]
  [int]$BatchSize = 5,
  [string]$CheckpointPath = '',
  [ValidateRange(0,5000)]
  [int]$MaxNewBatches = 0,
  [string]$NativeBatchPath = '',
  [string]$NativeResponsePath = '',
  [string]$NativeAgentId = '',
  [string]$NativeDispatchId = '',
  [switch]$Resume,
  [switch]$Apply,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\responses-api-bridge.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Root 'runtime\phase6_memory_eval.py'

function Throw-GeneratorError([string]$Code,[string]$Message) {
  throw [InvalidOperationException]::new("$Code|$Message")
}

function Read-GeneratorJson([string]$Path,[string]$Code) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Throw-GeneratorError $Code 'Required private answer-input artifact is missing.'
  }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Throw-GeneratorError $Code 'Required private answer-input artifact is invalid.' }
}

function Get-RequiredGeneratorText($Object,[string]$Name,[string]$Code,[int]$Maximum=8000) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { Throw-GeneratorError $Code "Missing field: $Name" }
  $value = [string]$Object.PSObject.Properties[$Name].Value
  if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt $Maximum) { Throw-GeneratorError $Code "Invalid field: $Name" }
  return $value
}

function Get-RequiredGeneratorBoolean($Object,[string]$Name,[string]$Code) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name] -or $Object.PSObject.Properties[$Name].Value -isnot [bool]) {
    Throw-GeneratorError $Code "Boolean field required: $Name"
  }
  return [bool]$Object.PSObject.Properties[$Name].Value
}

function Get-RequiredGeneratorInteger($Object,[string]$Name,[string]$Code) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { Throw-GeneratorError $Code "Missing field: $Name" }
  $value = $Object.PSObject.Properties[$Name].Value
  if ($value -is [bool]) { Throw-GeneratorError $Code "Integer field required: $Name" }
  try { $result = [int]$value } catch { Throw-GeneratorError $Code "Integer field required: $Name" }
  if ([string]$value -notmatch '^\d+$') { Throw-GeneratorError $Code "Integer field required: $Name" }
  return $result
}

function Get-AnswerInputPreflight([string]$Path) {
  if (-not (Test-Path -LiteralPath $Runtime -PathType Leaf)) { Throw-GeneratorError 'PHASE6_RUNTIME_MISSING' 'Phase 6 evaluator runtime is missing.' }
  $fullPath = [IO.Path]::GetFullPath($Path)
  $python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $python -or [string]::IsNullOrWhiteSpace([string]$python.Source)) { Throw-GeneratorError 'PHASE6_PYTHON_MISSING' 'Phase 6 answer-input preflight requires a resolvable Python executable.' }
  $raw = @(& $python.Source $Runtime 'validate-answer-input' '--answer-input' $fullPath 2>&1)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  try { $result = $text | ConvertFrom-Json } catch { Throw-GeneratorError 'ANSWER_INPUT_PREFLIGHT_FAILED' 'Private answer-input preflight returned invalid output.' }
  if ($exitCode -ne 0 -or $result.ok -ne $true) {
    $code = if ($null -ne $result.PSObject.Properties['code']) { [string]$result.code } else { 'ANSWER_INPUT_PREFLIGHT_FAILED' }
    Throw-GeneratorError $code 'Private answer-input preflight rejected the artifact.'
  }
  return $result
}

function Get-PrivateOutputPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { Throw-GeneratorError 'ANSWER_OUTPUT_REQUIRED' 'A private answer artifact output path is required.' }
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $fullPath) { Throw-GeneratorError 'ANSWER_OUTPUT_EXISTS' 'Refusing to overwrite an existing private answer artifact.' }
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $statePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($statePath,[StringComparison]::OrdinalIgnoreCase)) {
    Throw-GeneratorError 'ANSWER_OUTPUT_NOT_PRIVATE' 'Answer artifacts inside the package must be written under private-state.'
  }
  $parent = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  return $fullPath
}

function Get-ExistingPrivateArtifactPath([string]$Path,[string]$Code,[string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Throw-GeneratorError $Code "Required $Label artifact is missing."
  }
  $fullPath = [IO.Path]::GetFullPath($Path)
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $statePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($statePath,[StringComparison]::OrdinalIgnoreCase)) {
    Throw-GeneratorError $Code "$Label artifacts inside the package must be under private-state."
  }
  return $fullPath
}

function Write-GeneratorJsonAtomic([string]$Path,$Value) {
  $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
  $backup = "$Path.$([guid]::NewGuid().ToString('N')).bak"
  try {
    $text = $Value | ConvertTo-Json -Depth 24
    [IO.File]::WriteAllText($temporary,$text + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporary,$Path,$backup) }
    else { [IO.File]::Move($temporary,$Path) }
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
  }
}

function Get-PrivateCheckpointPath([string]$OutputPath,[string]$RequestedPath) {
  $candidate = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { $OutputPath + '.checkpoint.json' } else { $RequestedPath }
  $fullPath = [IO.Path]::GetFullPath($candidate)
  if ($fullPath -ieq [IO.Path]::GetFullPath($OutputPath)) { Throw-GeneratorError 'PHASE6_CHECKPOINT_OUTPUT_COLLISION' 'Checkpoint and answer artifact paths must be different.' }
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $statePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($statePath,[StringComparison]::OrdinalIgnoreCase)) {
    Throw-GeneratorError 'PHASE6_CHECKPOINT_NOT_PRIVATE' 'Checkpoints inside the package must be written under private-state.'
  }
  $parent = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  return $fullPath
}

function Get-GeneratorConnection {
  $connection = Resolve-SuperBrainResponsesConnection -ExplicitResponsesUrl $ResponsesUrl -PrimaryResponsesUrlEnvironment 'SUPER_BRAIN_ANSWER_RESPONSES_URL' -ApiKeyEnvironment $ApiKeyEnv
  if ([string]::IsNullOrWhiteSpace([string]$connection.responsesUrl)) { Throw-GeneratorError 'ANSWER_API_URL_REQUIRED' 'Answer generator Responses URL is required.' }
  if ([string]::IsNullOrWhiteSpace([string]$connection.apiKey)) { Throw-GeneratorError 'ANSWER_API_KEY_MISSING' "No answer-generator credential is available in $ApiKeyEnv." }
  return [pscustomobject]@{
    uri = [uri]$connection.responsesUrl
    apiKey = [string]$connection.apiKey
    endpointSource = [string]$connection.endpointSource
    credentialSource = [string]$connection.credentialSource
  }
}

function Get-AnswerCasePrompt($Case) {
  $query = Get-RequiredGeneratorText $Case 'query' 'ANSWER_INPUT_CASE_INVALID' 2000
  $evidenceLines = New-Object Collections.ArrayList
  foreach ($entry in @($Case.retrievedEvidence)) {
    $id = Get-RequiredGeneratorText $entry 'id' 'ANSWER_INPUT_EVIDENCE_INVALID' 120
    $text = Get-RequiredGeneratorText $entry 'text' 'ANSWER_INPUT_EVIDENCE_INVALID' 6000
    [void]$evidenceLines.Add("[$id] $text")
  }
  $evidence = if ($evidenceLines.Count -gt 0) { @($evidenceLines) -join [Environment]::NewLine } else { '(No retrieved evidence was supplied.)' }
  return @"
You are an independent answer generator for a blinded memory evaluation. Use only the retrieved evidence below. Do not infer hidden expected answers, invent facts, or use any information outside this request.

Return exactly one JSON object with this shape:
{"answerText":"compact answer that repeats the exact relevant value or values"}

If the evidence is insufficient, return exactly:
{"answerText":""}

Do not add prose or Markdown. The evaluator will derive citations only from exact value matches in the retrieved evidence.
Before returning, check that an insufficient-evidence response has an empty answerText.

Query:
$query

Retrieved evidence:
$evidence
"@
}

function ConvertTo-Phase6NativeCase($Case) {
  $evidence = New-Object Collections.ArrayList
  foreach ($entry in @($Case.retrievedEvidence)) {
    [void]$evidence.Add([pscustomobject]([ordered]@{
      id = Get-RequiredGeneratorText $entry 'id' 'NATIVE_BATCH_EVIDENCE_INVALID' 120
      text = Get-RequiredGeneratorText $entry 'text' 'NATIVE_BATCH_EVIDENCE_INVALID' 6000
    }))
  }
  return [pscustomobject]([ordered]@{
    id = Get-RequiredGeneratorText $Case 'id' 'NATIVE_BATCH_CASE_INVALID' 120
    query = Get-RequiredGeneratorText $Case 'query' 'NATIVE_BATCH_CASE_INVALID' 2000
    retrievedEvidence = @($evidence)
  })
}

function Get-Phase6NativeBatchDescriptor($Batch) {
  return [ordered]@{
    schema = [string]$Batch.schema
    workflow = [string]$Batch.workflow
    batchId = [string]$Batch.batchId
    setHash = [string]$Batch.setHash
    inputHash = [string]$Batch.inputHash
    modelId = [string]$Batch.modelId
    cases = @($Batch.cases)
    privacy = [ordered]@{
      expectedAnswerDataAvailable = $Batch.privacy.expectedAnswerDataAvailable
      rawExpectedDataStored = $Batch.privacy.rawExpectedDataStored
      rawModelTranscriptStored = $Batch.privacy.rawModelTranscriptStored
    }
  }
}

function Get-Phase6NativeBatchHash($Batch) {
  return Get-SuperBrainTextSha256 ((Get-Phase6NativeBatchDescriptor $Batch | ConvertTo-Json -Depth 24 -Compress))
}

function Get-Phase6NativeIdentity([string]$Value,[string]$Name) {
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 160 -or $text -notmatch '^[A-Za-z0-9._:-]+$') {
    Throw-GeneratorError 'NATIVE_DISPATCH_IDENTITY_INVALID' "Native agent $Name is invalid."
  }
  return $text
}

function Assert-Phase6NativeBatch($Batch,$Preflight,$AnswerInput) {
  if ($null -eq $Batch) { Throw-GeneratorError 'NATIVE_BATCH_INVALID' 'Native answer batch schema is invalid.' }
  $allowedBatchFields = @('schema','workflow','batchId','setHash','inputHash','modelId','cases','batchHash','privacy')
  $actualBatchFields = @($Batch.PSObject.Properties.Name)
  if (@($actualBatchFields | Where-Object { $_ -notin $allowedBatchFields }).Count -gt 0 -or @($allowedBatchFields | Where-Object { $_ -notin $actualBatchFields }).Count -gt 0) {
    Throw-GeneratorError 'NATIVE_BATCH_INVALID' 'Native answer batch must contain only the blinded batch contract.'
  }
  if ($null -eq $Batch.privacy) { Throw-GeneratorError 'NATIVE_BATCH_INVALID' 'Native answer batch privacy contract is missing.' }
  $allowedPrivacyFields = @('expectedAnswerDataAvailable','rawExpectedDataStored','rawModelTranscriptStored')
  $actualPrivacyFields = @($Batch.privacy.PSObject.Properties.Name)
  if (@($actualPrivacyFields | Where-Object { $_ -notin $allowedPrivacyFields }).Count -gt 0 -or @($allowedPrivacyFields | Where-Object { $_ -notin $actualPrivacyFields }).Count -gt 0) {
    Throw-GeneratorError 'NATIVE_BATCH_INVALID' 'Native answer batch privacy contract is invalid.'
  }
  if ((Get-RequiredGeneratorBoolean $Batch.privacy 'expectedAnswerDataAvailable' 'NATIVE_BATCH_INVALID') -ne $false -or
      (Get-RequiredGeneratorBoolean $Batch.privacy 'rawExpectedDataStored' 'NATIVE_BATCH_INVALID') -ne $false -or
      (Get-RequiredGeneratorBoolean $Batch.privacy 'rawModelTranscriptStored' 'NATIVE_BATCH_INVALID') -ne $false) {
    Throw-GeneratorError 'NATIVE_BATCH_INVALID' 'Native answer batch must attest that expected data and raw transcripts are absent.'
  }
  if ([string]$Batch.schema -ne 'super-brain.phase6-native-answer-batch.v1' -or [string]$Batch.workflow -ne 'phase6_memory_e2e') {
    Throw-GeneratorError 'NATIVE_BATCH_INVALID' 'Native answer batch schema is invalid.'
  }
  if ([string]$Batch.setHash -ne [string]$Preflight.setHash -or [string]$Batch.inputHash -ne [string]$Preflight.inputHash -or [string]$Batch.modelId -ne $Model) {
    Throw-GeneratorError 'NATIVE_BATCH_BINDING_MISMATCH' 'Native answer batch does not bind the current input and model.'
  }
  [void](Get-Phase6NativeIdentity ([string]$Batch.batchId) 'batch id')
  if ([string]$Batch.batchHash -ne (Get-Phase6NativeBatchHash $Batch)) {
    Throw-GeneratorError 'NATIVE_BATCH_HASH_MISMATCH' 'Native answer batch hash is invalid.'
  }
  $expected = @($AnswerInput.cases | Sort-Object id | ForEach-Object { ConvertTo-Phase6NativeCase $_ })
  $actual = @($Batch.cases | Sort-Object id)
  if ($actual.Count -ne $expected.Count) { Throw-GeneratorError 'NATIVE_BATCH_CASE_SET_MISMATCH' 'Native answer batch case coverage is invalid.' }
  for ($index = 0; $index -lt $expected.Count; $index++) {
    $left = $expected[$index] | ConvertTo-Json -Depth 16 -Compress
    $right = $actual[$index] | ConvertTo-Json -Depth 16 -Compress
    if ($left -ne $right) { Throw-GeneratorError 'NATIVE_BATCH_CASE_SET_MISMATCH' 'Native answer batch contains data outside the blinded input projection.' }
  }
}

function Get-AnswerResponseSchema($Cases) {
  return [ordered]@{
    type = 'object'
    additionalProperties = $false
    required = @('cases')
    properties = [ordered]@{
      cases = [ordered]@{
        type = 'array'
        minItems = @($Cases).Count
        maxItems = @($Cases).Count
        items = [ordered]@{
          type = 'object'
          additionalProperties = $false
          required = @('id','answerText')
          properties = [ordered]@{
            id = [ordered]@{ type='string'; maxLength=120 }
            answerText = [ordered]@{ type='string'; maxLength=8000 }
          }
        }
      }
    }
  }
}

function Get-AnswerBatchPrompt($Cases) {
  $blocks = New-Object Collections.ArrayList
  foreach ($case in @($Cases | Sort-Object id)) {
    $query = Get-RequiredGeneratorText $case 'query' 'ANSWER_INPUT_CASE_INVALID' 2000
    $evidenceLines = New-Object Collections.ArrayList
    foreach ($entry in @($case.retrievedEvidence)) {
      $id = Get-RequiredGeneratorText $entry 'id' 'ANSWER_INPUT_EVIDENCE_INVALID' 120
      $text = Get-RequiredGeneratorText $entry 'text' 'ANSWER_INPUT_EVIDENCE_INVALID' 6000
      [void]$evidenceLines.Add("[$id] $text")
    }
    $evidence = if ($evidenceLines.Count -gt 0) { @($evidenceLines) -join [Environment]::NewLine } else { '(No retrieved evidence was supplied.)' }
    [void]$blocks.Add(@"
Case id: $($case.id)
Query: $query
Evidence limited to this case:
$evidence
"@)
  }
  return @"
You are an independent answer generator for a blinded memory evaluation. Return exactly one JSON object with a cases array. Each item must contain its exact case id and an answerText.

Use only the evidence inside the matching case. Do not transfer facts, values, or citations between cases. Each non-empty answerText must repeat the exact relevant value or values from its own evidence. When that case's evidence is insufficient, use an empty answerText. Do not add prose or Markdown.

$(($blocks -join [Environment]::NewLine + [Environment]::NewLine))
"@
}

function Get-GeneratorProbeCase {
  return [pscustomobject]@{
    id = 'transport-probe'
    query = 'What is the transport verification value?'
    retrievedEvidence = @(
      [pscustomobject]@{
        id = 'transport-probe-evidence'
        text = '[CURRENT][VERIFIED] Transport verification value is probe-ok.'
        layer = 'transport'
      }
    )
  }
}

function Get-ExactEvidenceIdsForAnswer([string]$AnswerText,$Case) {
  # Treat only compact answer wrappers as non-claims. Every remaining token must
  # occur in the evidence for this case, which accepts values such as "aurora"
  # without allowing an unrelated word to be silently cited.
  $wrapperTokens = @('answer','answers','current','detail','details','for','from','given','information','please','relevant','requested','result','results','the','this','value','values','with')
  $tokens = @(
    [regex]::Matches($AnswerText.ToLowerInvariant(),'[\p{L}\p{N}][\p{L}\p{N}_.:-]{2,}') |
      ForEach-Object { $_.Value.TrimEnd([char[]]@('.',':')) } |
      Where-Object { $_ -notin $wrapperTokens } |
      Select-Object -Unique
  )
  if ($tokens.Count -eq 0) { return @() }
  $ids = New-Object Collections.ArrayList
  foreach ($token in $tokens) {
    $matchedEntries = @($Case.retrievedEvidence | Where-Object { ([string]$_.text).ToLowerInvariant().Contains($token) })
    if ($matchedEntries.Count -eq 0) { return @() }
    foreach ($entry in $matchedEntries) { [void]$ids.Add([string]$entry.id) }
  }
  return @($ids | Select-Object -Unique | Select-Object -First 4)
}

function Test-ExplicitEvidenceAbstention([string]$AnswerText) {
  $text = $AnswerText.Trim().ToLowerInvariant()
  if ($text.Length -eq 0 -or $text.Length -gt 600) { return $false }
  return $text -match '(insufficient|not enough|not available|not provided|not specified|cannot determine|can''t determine|cannot answer|unknown|no evidence|no information|does not contain|doesn''t contain|无法|不能确定|信息不足|未提供|不可用|没有.*信息|未知)'
}

function ConvertFrom-GeneratorAnswer([string]$Text,$Case,[string]$ReportedModel) {
  $clean = $Text.Trim() -replace '^```(?:json)?\s*','' -replace '\s*```$',''
  try { $value = $clean | ConvertFrom-Json }
  catch {
    $firstObject = $clean.IndexOf('{')
    $lastObject = $clean.LastIndexOf('}')
    if ($firstObject -lt 0 -or $lastObject -le $firstObject) { Throw-GeneratorError 'ANSWER_RESPONSE_INVALID' 'Answer generator response is not valid JSON.' }
    try { $value = $clean.Substring($firstObject,$lastObject - $firstObject + 1) | ConvertFrom-Json }
    catch { Throw-GeneratorError 'ANSWER_RESPONSE_INVALID' 'Answer generator response is not one valid JSON object.' }
  }
  if ($null -eq $value.PSObject.Properties['answerText'] -or $value.answerText -isnot [string] -or ([string]$value.answerText).Length -gt 8000) {
    Throw-GeneratorError 'ANSWER_RESPONSE_INVALID' 'Answer generator response has an invalid answerText.'
  }
  $answerText = [string]$value.answerText
  if ([string]::IsNullOrWhiteSpace($answerText)) {
    $abstained = $true
    $safeClaims = @()
  } else {
    [object[]]$evidenceIds = @(Get-ExactEvidenceIdsForAnswer $answerText $Case)
    if ($evidenceIds.Count -eq 0) {
      if (Test-ExplicitEvidenceAbstention $answerText) {
        $abstained = $true
        $answerText = ''
        $safeClaims = @()
      } else {
        Throw-GeneratorError 'ANSWER_RESPONSE_UNGROUNDED' 'Answer text has no exact match in the evidence supplied to that case.'
      }
    } else {
      $abstained = $false
      $safeClaims = @([pscustomobject]@{ id='claim-1'; evidenceIds=[object[]]$evidenceIds })
    }
  }
  return [pscustomobject]@{
    id = Get-RequiredGeneratorText $Case 'id' 'ANSWER_INPUT_CASE_INVALID' 120
    caseHash = Get-RequiredGeneratorText $Case 'caseHash' 'ANSWER_INPUT_CASE_INVALID' 64
    abstained = $abstained
    answerText = $answerText
    claimCount = @($safeClaims).Count
    claims = @($safeClaims)
    responseModel = $ReportedModel
  }
}

function ConvertFrom-GeneratorBatch([string]$Text,$Cases,[string]$ReportedModel) {
  $clean = $Text.Trim() -replace '^```(?:json)?\s*','' -replace '\s*```$',''
  try { $value = $clean | ConvertFrom-Json }
  catch {
    $firstObject = $clean.IndexOf('{')
    $lastObject = $clean.LastIndexOf('}')
    if ($firstObject -lt 0 -or $lastObject -le $firstObject) { Throw-GeneratorError 'ANSWER_RESPONSE_INVALID' 'Answer generator batch response is not valid JSON.' }
    try { $value = $clean.Substring($firstObject,$lastObject - $firstObject + 1) | ConvertFrom-Json }
    catch { Throw-GeneratorError 'ANSWER_RESPONSE_INVALID' 'Answer generator batch response is not one valid JSON object.' }
  }
  if ($null -eq $value.PSObject.Properties['cases']) { Throw-GeneratorError 'ANSWER_RESPONSE_INVALID' 'Answer generator batch response has no cases.' }
  $expected = @{}
  foreach ($case in @($Cases)) { $expected[[string]$case.id] = $case }
  $answers = @{}
  foreach ($item in @($value.cases)) {
    $id = Get-RequiredGeneratorText $item 'id' 'ANSWER_RESPONSE_INVALID' 120
    if ($answers.ContainsKey($id) -or -not $expected.ContainsKey($id)) { Throw-GeneratorError 'ANSWER_RESPONSE_INVALID' 'Answer generator batch case ids are invalid.' }
    $answers[$id] = ConvertFrom-GeneratorAnswer ($item | ConvertTo-Json -Depth 10 -Compress) $expected[$id] $ReportedModel
  }
  if ($answers.Count -ne $expected.Count) { Throw-GeneratorError 'ANSWER_RESPONSE_INVALID' 'Answer generator batch does not cover every case exactly once.' }
  return @($answers.Keys | Sort-Object | ForEach-Object { $answers[$_] })
}

function Get-Phase6ResponseModelEvidenceHash($Cases) {
  $parts = @($Cases | Sort-Object id | ForEach-Object { ([string]$_.id) + "`n" + ([string]$_.responseModel) })
  return Get-SuperBrainTextSha256 ($parts -join "`n")
}

function Get-Phase6GeneratorMetadata($Preflight,$Connection,$TransportProbe) {
  $scriptHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $runtimeHash = (Get-FileHash -LiteralPath $Runtime -Algorithm SHA256).Hash.ToLowerInvariant()
  $manifestPath = Join-Path $Root 'manifest.json'
  $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $endpointHash = Get-SuperBrainTextSha256 $Connection.uri.GetLeftPart([UriPartial]::Authority)
  $configFingerprint = Get-SuperBrainTextSha256 ((@(
    'phase6-memory-e2e',[string]$Preflight.setHash,[string]$Preflight.inputHash,$Model,$ReasoningEffort,$TimeoutSeconds,$BatchSize,$MaxBatchAttempts,
    $scriptHash,$runtimeHash,$manifestHash,$endpointHash
  ) -join "`n"))
  return [pscustomobject]@{
    scriptHash=$scriptHash
    runtimeHash=$runtimeHash
    manifestHash=$manifestHash
    endpointHash=$endpointHash
    configFingerprint=$configFingerprint
    transportProbeReceiptSha256=[string]$TransportProbe.receiptSha256
  }
}

function Get-Phase6BatchCaseSetSha256($Cases) {
  return Get-SuperBrainTextSha256 ((@($Cases | ForEach-Object { ([string]$_.id) + "`n" + ([string]$_.caseHash) }) -join "`n"))
}

function New-Phase6GenerationCheckpoint($Preflight,$Metadata,$OrderedCases) {
  $batches = New-Object Collections.ArrayList
  $batchIndex = 0
  for ($offset = 0; $offset -lt $OrderedCases.Count; $offset += $BatchSize) {
    $last = [Math]::Min($offset + $BatchSize - 1,$OrderedCases.Count - 1)
    $batchCases = @($OrderedCases[$offset..$last])
    [void]$batches.Add([pscustomobject]@{
      index=$batchIndex
      caseIds=@($batchCases | ForEach-Object { [string]$_.id })
      caseSetSha256=(Get-Phase6BatchCaseSetSha256 $batchCases)
      status='pending'
      attemptCount=0
      responseReceiptSha256=''
      responseModel=''
      startedAtUtc=''
      completedAtUtc=''
      errorCode=''
    })
    $batchIndex++
  }
  return [pscustomobject]@{
    schema='super-brain.phase6-answer-checkpoint.v1'
    status='active'
    createdAtUtc=(Get-Date).ToUniversalTime().ToString('o')
    updatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
    identity=[pscustomobject]@{
      setHash=[string]$Preflight.setHash
      inputHash=[string]$Preflight.inputHash
      configFingerprint=$Metadata.configFingerprint
      model=$Model
      reasoningEffort=$ReasoningEffort
      timeoutSeconds=$TimeoutSeconds
      batchSize=$BatchSize
      maxBatchAttempts=$MaxBatchAttempts
      endpointSha256=$Metadata.endpointHash
      transportProbeReceiptSha256=$Metadata.transportProbeReceiptSha256
    }
    batches=@($batches)
    completedAnswers=@()
    privacy=[pscustomobject]@{privateCheckpointOnly=$true;credentialStored=$false;rawResponseStored=$false;rawExpectedDataStored=$false}
  }
}

function Write-Phase6GenerationCheckpoint([string]$Path,$Checkpoint) {
  $Checkpoint.updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  Write-GeneratorJsonAtomic $Path $Checkpoint
}

function Get-Phase6CheckpointExpectedIdentity($Preflight,$Metadata) {
  return [ordered]@{
    setHash=[string]$Preflight.setHash
    inputHash=[string]$Preflight.inputHash
    configFingerprint=$Metadata.configFingerprint
    model=$Model
    reasoningEffort=$ReasoningEffort
    timeoutSeconds=$TimeoutSeconds
    batchSize=$BatchSize
    maxBatchAttempts=$MaxBatchAttempts
    endpointSha256=$Metadata.endpointHash
    transportProbeReceiptSha256=$Metadata.transportProbeReceiptSha256
  }
}

function ConvertFrom-Phase6CheckpointAnswer($Entry,$Case) {
  $id = Get-RequiredGeneratorText $Entry 'id' 'PHASE6_CHECKPOINT_INVALID' 120
  if ($id -ne [string]$Case.id) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint answer id does not match its input case.' }
  if ([string](Get-RequiredGeneratorText $Entry 'caseHash' 'PHASE6_CHECKPOINT_INVALID' 64) -ne [string]$Case.caseHash) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint answer case hash does not match its input case.' }
  $responseModel = Get-RequiredGeneratorText $Entry 'responseModel' 'PHASE6_CHECKPOINT_INVALID' 160
  if ($responseModel -ne $Model) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint answer model is invalid.' }
  if ($null -eq $Entry.PSObject.Properties['answerText'] -or $Entry.answerText -isnot [string] -or ([string]$Entry.answerText).Length -gt 8000) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint answer text is invalid.' }
  if ($null -eq $Entry.PSObject.Properties['abstained'] -or $Entry.abstained -isnot [bool]) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint answer abstention state is invalid.' }
  $normalized = ConvertFrom-GeneratorAnswer (([pscustomobject]@{answerText=[string]$Entry.answerText} | ConvertTo-Json -Compress)) $Case $responseModel
  if ([bool]$Entry.abstained -ne [bool]$normalized.abstained -or (Get-RequiredGeneratorInteger $Entry 'claimCount' 'PHASE6_CHECKPOINT_INVALID') -ne [int]$normalized.claimCount) {
    Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint answer grounding state is invalid.'
  }
  $storedClaims = @($Entry.claims)
  $normalizedClaims = @($normalized.claims)
  if ($storedClaims.Count -ne $normalizedClaims.Count) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint answer claim count is invalid.' }
  for ($index = 0; $index -lt $normalizedClaims.Count; $index++) {
    $stored = $storedClaims[$index]
    $expected = $normalizedClaims[$index]
    if ($null -eq $stored -or [string](Get-RequiredGeneratorText $stored 'id' 'PHASE6_CHECKPOINT_INVALID' 120) -ne [string]$expected.id -or ((@($stored.evidenceIds) -join "`n") -ne (@($expected.evidenceIds) -join "`n"))) {
      Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint answer claims are invalid.'
    }
  }
  return $normalized
}

function Read-Phase6GenerationCheckpoint([string]$Path,$Preflight,$Metadata,$OrderedCases) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Throw-GeneratorError 'PHASE6_CHECKPOINT_MISSING' 'No checkpoint exists at the requested resume path.' }
  $checkpoint = Read-GeneratorJson $Path 'PHASE6_CHECKPOINT_INVALID'
  if ([string]$checkpoint.schema -ne 'super-brain.phase6-answer-checkpoint.v1' -or $null -eq $checkpoint.identity -or $null -eq $checkpoint.batches -or $null -eq $checkpoint.completedAnswers) {
    Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint schema or required state is invalid.'
  }
  foreach ($entry in (Get-Phase6CheckpointExpectedIdentity $Preflight $Metadata).GetEnumerator()) {
    if ($null -eq $checkpoint.identity.PSObject.Properties[$entry.Key] -or [string]$checkpoint.identity.PSObject.Properties[$entry.Key].Value -ne [string]$entry.Value) {
      Throw-GeneratorError 'PHASE6_CHECKPOINT_BINDING_MISMATCH' "Checkpoint does not match the current $($entry.Key)."
    }
  }
  $expectedBatchCount = [int][Math]::Ceiling($OrderedCases.Count / [double]$BatchSize)
  if (@($checkpoint.batches).Count -ne $expectedBatchCount) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint batch count is invalid.' }
  $expectedCompletedIds = @{}
  for ($index = 0; $index -lt $expectedBatchCount; $index++) {
    $batch = @($checkpoint.batches)[$index]
    $offset = $index * $BatchSize
    $last = [Math]::Min($offset + $BatchSize - 1,$OrderedCases.Count - 1)
    $expectedCases = @($OrderedCases[$offset..$last])
    if ([int]$batch.index -ne $index -or ((@($batch.caseIds) -join "`n") -ne (@($expectedCases | ForEach-Object { [string]$_.id }) -join "`n")) -or [string]$batch.caseSetSha256 -ne (Get-Phase6BatchCaseSetSha256 $expectedCases)) {
      Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint batch layout is invalid.'
    }
    if ([string]$batch.status -notin @('pending','complete','blocked','in_progress')) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint batch status is invalid.' }
    if ([int]$batch.attemptCount -lt 0 -or [int]$batch.attemptCount -gt 1) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint batch attempt count is invalid.' }
    if ([string]$batch.status -eq 'complete') {
      if ([int]$batch.attemptCount -ne 1 -or [string]::IsNullOrWhiteSpace([string]$batch.responseReceiptSha256) -or [string]$batch.responseModel -ne $Model) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Completed checkpoint batch evidence is invalid.' }
      foreach ($case in $expectedCases) { $expectedCompletedIds[[string]$case.id] = $case }
    } elseif ([string]$batch.status -eq 'pending') {
      if ([int]$batch.attemptCount -ne 0) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Pending checkpoint batch has an attempt.' }
    } elseif ([string]$batch.status -eq 'in_progress') {
      Throw-GeneratorError 'PHASE6_CHECKPOINT_INDETERMINATE' 'A batch was marked in progress when execution stopped; it cannot be replayed automatically.'
    } else {
      Throw-GeneratorError 'PHASE6_CHECKPOINT_BLOCKED' 'A prior batch failed. Start a new controlled evaluation run instead of replaying it automatically.'
    }
  }
  $actualCompletedIds = @{}
  foreach ($answer in @($checkpoint.completedAnswers)) {
    $id = Get-RequiredGeneratorText $answer 'id' 'PHASE6_CHECKPOINT_INVALID' 120
    if ($actualCompletedIds.ContainsKey($id) -or -not $expectedCompletedIds.ContainsKey($id)) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint completed answers do not match completed batches.' }
    [void](ConvertFrom-Phase6CheckpointAnswer $answer $expectedCompletedIds[$id])
    $actualCompletedIds[$id] = $true
  }
  if ($actualCompletedIds.Count -ne $expectedCompletedIds.Count) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint completed answer count is invalid.' }
  foreach ($id in $expectedCompletedIds.Keys) { if (-not $actualCompletedIds.ContainsKey($id)) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint is missing a completed answer.' } }
  $allComplete = @($checkpoint.batches | Where-Object { [string]$_.status -ne 'complete' }).Count -eq 0
  if ($allComplete -and [string]$checkpoint.status -ne 'complete') { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint completion state is invalid.' }
  if (-not $allComplete -and [string]$checkpoint.status -ne 'active') { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint active state is invalid.' }
  return $checkpoint
}

function Get-Phase6AnswerCasesFromCheckpoint($AnswerInput,$Checkpoint) {
  $answerById = @{}
  foreach ($entry in @($Checkpoint.completedAnswers)) { $answerById[[string]$entry.id] = $entry }
  $result = New-Object Collections.ArrayList
  foreach ($case in @($AnswerInput.cases | Sort-Object id)) {
    $entry = $answerById[[string]$case.id]
    if ($null -eq $entry) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Checkpoint does not contain every answer.' }
    [void]$result.Add((ConvertFrom-Phase6CheckpointAnswer $entry $case))
  }
  return @($result)
}

function Get-GeneratorStatus {
  $connection = Resolve-SuperBrainResponsesConnection -ExplicitResponsesUrl $ResponsesUrl -PrimaryResponsesUrlEnvironment 'SUPER_BRAIN_ANSWER_RESPONSES_URL' -ApiKeyEnvironment $ApiKeyEnv
  $urlConfigured = -not [string]::IsNullOrWhiteSpace([string]$connection.responsesUrl)
  $keyConfigured = -not [string]::IsNullOrWhiteSpace([string]$connection.apiKey)
  return [pscustomobject]@{
    ok = $true
    action = 'Status'
    schema = 'super-brain.phase6-answer-generator-status.v1'
    status = if ($urlConfigured -and $keyConfigured) { 'configured_unverified' } else { 'configuration_required' }
    model = $Model
    reasoningEffort = $ReasoningEffort
    responsesUrlConfigured = $urlConfigured
    apiKeyConfigured = $keyConfigured
    endpointSource = [string]$connection.endpointSource
    credentialSource = [string]$connection.credentialSource
    credentialStored = $false
    rawResponseStored = $false
  }
}

function Invoke-GeneratorProbe {
  if (-not $Apply) { Throw-GeneratorError 'PROBE_APPLY_REQUIRED' 'Answer-generator probing requires explicit -Apply.' }
  $connection = Get-GeneratorConnection
  # Probe the same structured Responses capability used by generation without
  # exposing a sealed input, expected answer, or user memory.
  $probeCase = Get-GeneratorProbeCase
  $probe = Invoke-SuperBrainResponsesProbe -Uri $connection.uri -ApiKey $connection.apiKey -Model $Model -ReasoningEffort $ReasoningEffort -RequestInput (Get-AnswerBatchPrompt @($probeCase)) -JsonSchema (Get-AnswerResponseSchema @($probeCase)) -MaxOutputTokens 4096 -TimeoutSeconds $TimeoutSeconds -MaxAttempts $ProbeMaxAttempts -RetryDelayMilliseconds $ProbeRetryDelayMilliseconds
  $result = $probe.result
  [void](Get-SuperBrainResponsesId $result.response)
  $receipt = Write-SuperBrainResponsesTransportProbeReceipt -Scope 'phase6-answer' -Uri $connection.uri -Model $Model -ReasoningEffort $ReasoningEffort
  return [pscustomobject]@{
    ok = $true
    action = 'Probe'
    schema = 'super-brain.phase6-answer-generator-probe.v1'
    status = 'reachable'
    model = $Model
    reportedModelId = $result.reportedModel
    modelIdentityVerified = $true
    reasoningEffort = $ReasoningEffort
    endpointSource = $connection.endpointSource
    credentialSource = $connection.credentialSource
    transportProbeReceiptSha256 = $receipt.sha256
    probeAttemptCount = [int]$probe.attemptCount
    transportRetryCount = [int]$probe.retryCount
    credentialStored = $false
    rawResponseStored = $false
  }
}

function Export-Phase6NativeAgentBatch {
  if (-not $Apply) { Throw-GeneratorError 'NATIVE_EXPORT_APPLY_REQUIRED' 'Native answer batch export requires explicit -Apply.' }
  $preflight = Get-AnswerInputPreflight $AnswerInputPath
  $answerInput = Read-GeneratorJson $AnswerInputPath 'ANSWER_INPUT_INVALID'
  $output = Get-PrivateOutputPath $OutputPath
  $batch = [pscustomobject]([ordered]@{
    schema = 'super-brain.phase6-native-answer-batch.v1'
    workflow = 'phase6_memory_e2e'
    batchId = 'phase6-native-' + [guid]::NewGuid().ToString('N')
    setHash = [string]$preflight.setHash
    inputHash = [string]$preflight.inputHash
    modelId = $Model
    cases = @($answerInput.cases | Sort-Object id | ForEach-Object { ConvertTo-Phase6NativeCase $_ })
    batchHash = ''
    privacy = [pscustomobject]@{ expectedAnswerDataAvailable=$false; rawExpectedDataStored=$false; rawModelTranscriptStored=$false }
  })
  $batch.batchHash = Get-Phase6NativeBatchHash $batch
  Assert-Phase6NativeBatch $batch $preflight $answerInput
  Write-GeneratorJsonAtomic $output $batch
  return [pscustomobject]@{
    ok=$true; action='ExportNative'; schema='super-brain.phase6-native-answer-export-result.v1'; status='native_batch_exported_private'
    outputPath=$output; outputSha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant(); batchId=[string]$batch.batchId; batchHash=[string]$batch.batchHash
    inputHash=[string]$preflight.inputHash; caseCount=@($batch.cases).Count; model=$Model; expectedAnswerDataAvailable=$false; rawModelTranscriptStored=$false
  }
}

function Import-Phase6NativeAgentBatch {
  if (-not $Apply) { Throw-GeneratorError 'NATIVE_IMPORT_APPLY_REQUIRED' 'Native answer batch import requires explicit -Apply.' }
  $preflight = Get-AnswerInputPreflight $AnswerInputPath
  $answerInput = Read-GeneratorJson $AnswerInputPath 'ANSWER_INPUT_INVALID'
  $batchPath = Get-ExistingPrivateArtifactPath $NativeBatchPath 'NATIVE_BATCH_MISSING' 'native batch'
  $responsePath = Get-ExistingPrivateArtifactPath $NativeResponsePath 'NATIVE_RESPONSE_MISSING' 'native response'
  $output = Get-PrivateOutputPath $OutputPath
  $batch = Read-GeneratorJson $batchPath 'NATIVE_BATCH_INVALID'
  Assert-Phase6NativeBatch $batch $preflight $answerInput
  $response = Read-GeneratorJson $responsePath 'NATIVE_RESPONSE_INVALID'
  $allowedResponseFields = @('schema','batchId','batchHash','cases')
  $unexpectedResponseFields = @($response.PSObject.Properties.Name | Where-Object { $_ -notin $allowedResponseFields })
  if ([string]$response.schema -ne 'super-brain.host-native-agent-response.v1' -or [string]$response.batchId -ne [string]$batch.batchId -or [string]$response.batchHash -ne [string]$batch.batchHash -or $unexpectedResponseFields.Count -gt 0) {
    Throw-GeneratorError 'NATIVE_RESPONSE_INVALID' 'Native agent response must contain only the bound batch answer payload.'
  }
  $normalizedPayload = [pscustomobject]@{ cases=@($response.cases) } | ConvertTo-Json -Depth 16 -Compress
  $answerCases = @(ConvertFrom-GeneratorBatch $normalizedPayload @($answerInput.cases | Sort-Object id) $Model)
  $agentId = Get-Phase6NativeIdentity $NativeAgentId 'id'
  $dispatchId = Get-Phase6NativeIdentity $NativeDispatchId 'dispatch id'
  $scriptHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $responseHash = (Get-FileHash -LiteralPath $responsePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $receipt = [pscustomobject]([ordered]@{
    schema='super-brain.host-native-agent-dispatch-receipt.v1'; kind='host_native_agent_blinded_input'; dispatchId=$dispatchId; agentId=$agentId; modelId=$Model
    batchId=[string]$batch.batchId; batchHash=[string]$batch.batchHash; inputHash=[string]$preflight.inputHash; responseSha256=$responseHash; caseCount=@($answerCases).Count
    createdAtUtc=(Get-Date).ToUniversalTime().ToString('o'); expectedAnswerDataAvailable=$false; rawModelTranscriptStored=$false
  })
  $receiptPath = $output + '.native-dispatch-receipt.json'
  if (Test-Path -LiteralPath $receiptPath) { Throw-GeneratorError 'NATIVE_RECEIPT_EXISTS' 'Native dispatch receipt already exists for this output path.' }
  Write-GeneratorJsonAtomic $receiptPath $receipt
  $receiptHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $endpointHash = Get-SuperBrainTextSha256 'codex-desktop-native-agent-host-v1'
  $responseReceipt = Get-SuperBrainTextSha256 ((@([string]$preflight.inputHash,[string]$batch.batchHash,$responseHash,$receiptHash) -join "`n"))
  $artifact = [pscustomobject]@{
    schema='super-brain.memory-e2e-answer-artifact.v1'
    setHash=[string]$answerInput.setHash
    provenance=[pscustomobject]@{
      schema='super-brain.memory-e2e-answer-provenance.v2'; kind='host_native_agent_blinded_input'; generatorId='super-brain.phase6-native-agent-importer'; generatorVersion=$scriptHash; generatorSha256=$scriptHash
      runId='phase6-native-' + $responseReceipt.Substring(0,32); modelId=$Model; modelVersion=$Model; endpointSha256=$endpointHash; responseReceiptSha256=$responseReceipt
      responseCount=1; caseCount=@($answerCases).Count; responseModelEvidenceSha256=(Get-Phase6ResponseModelEvidenceHash @($answerCases)); independentExecution=$true
      expectedAnswerDataAvailable=$false; inputSchema='super-brain.memory-e2e-answer-input.v1'; inputHash=[string]$preflight.inputHash; rawResponseStored=$false
      hostedNativeAgent=$true; hostDispatchReceiptSha256=$receiptHash; hostAgentId=$agentId; modelIdentityVerified=$true
    }
    cases=@($answerCases)
  }
  Write-GeneratorJsonAtomic $output $artifact
  return [pscustomobject]@{
    ok=$true; action='ImportNative'; schema='super-brain.phase6-native-answer-import-result.v1'; status='native_agent_artifact_imported_private'
    outputPath=$output; outputSha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant(); receiptPath=$receiptPath; receiptSha256=$receiptHash
    nativeBatchSha256=[string]$batch.batchHash; nativeResponseSha256=$responseHash; inputHash=[string]$preflight.inputHash; caseCount=@($answerCases).Count; model=$Model
    modelIdentityVerified=$true; expectedAnswerDataAvailable=$false; rawModelTranscriptStored=$false
  }
}

function Invoke-AnswerArtifactGeneration {
  if (-not $Apply) { Throw-GeneratorError 'GENERATE_APPLY_REQUIRED' 'Answer artifact generation requires explicit -Apply.' }
  $preflight = Get-AnswerInputPreflight $AnswerInputPath
  $answerInput = Read-GeneratorJson $AnswerInputPath 'ANSWER_INPUT_INVALID'
  $output = Get-PrivateOutputPath $OutputPath
  $connection = Get-GeneratorConnection
  $transportProbe = Assert-SuperBrainResponsesTransportProbeReceipt -Scope 'phase6-answer' -Uri $connection.uri -Model $Model -ReasoningEffort $ReasoningEffort
  $orderedCases = @($answerInput.cases | Sort-Object id)
  $metadata = Get-Phase6GeneratorMetadata $preflight $connection $transportProbe
  $checkpointPath = Get-PrivateCheckpointPath $output $CheckpointPath
  $checkpoint = if ($Resume) {
    Read-Phase6GenerationCheckpoint $checkpointPath $preflight $metadata $orderedCases
  } else {
    if (Test-Path -LiteralPath $checkpointPath -PathType Leaf) { Throw-GeneratorError 'PHASE6_CHECKPOINT_EXISTS' 'A checkpoint already exists. Use -Resume after checking its state.' }
    $fresh = New-Phase6GenerationCheckpoint $preflight $metadata $orderedCases
    Write-Phase6GenerationCheckpoint $checkpointPath $fresh
    $fresh
  }
  $newBatchCount = 0
  for ($batchIndex = 0; $batchIndex -lt @($checkpoint.batches).Count; $batchIndex++) {
    $batch = @($checkpoint.batches)[$batchIndex]
    if ([string]$batch.status -eq 'complete') { continue }
    if ([string]$batch.status -ne 'pending') { Throw-GeneratorError 'PHASE6_CHECKPOINT_INVALID' 'Only pending batches may be sent.' }
    if ($MaxNewBatches -gt 0 -and $newBatchCount -ge $MaxNewBatches) {
      return [pscustomobject]@{
        ok=$true; action='Generate'; schema='super-brain.phase6-answer-generator-result.v1'; status='checkpointed_partial'
        checkpointPath=$checkpointPath; checkpointSha256=(Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash.ToLowerInvariant()
        completedCaseCount=@($checkpoint.completedAnswers).Count; completedBatchCount=@($checkpoint.batches | Where-Object { [string]$_.status -eq 'complete' }).Count
        remainingBatchCount=@($checkpoint.batches | Where-Object { [string]$_.status -eq 'pending' }).Count; resumed=[bool]$Resume
        credentialStored=$false; rawResponseStored=$false
      }
    }
    $offset = $batchIndex * $BatchSize
    $last = [Math]::Min($offset + $BatchSize - 1,$orderedCases.Count - 1)
    $batchCases = @($orderedCases[$offset..$last])
    $batch.status = 'in_progress'
    $batch.attemptCount = 1
    $batch.startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $checkpoint.status = 'active'
    Write-Phase6GenerationCheckpoint $checkpointPath $checkpoint
    try {
      $result = Invoke-SuperBrainResponsesRequest -Uri $connection.uri -ApiKey $connection.apiKey -Model $Model -ReasoningEffort $ReasoningEffort -RequestInput (Get-AnswerBatchPrompt $batchCases) -JsonSchema (Get-AnswerResponseSchema $batchCases) -MaxOutputTokens 4096 -TimeoutSeconds $TimeoutSeconds
      $batchAnswers = @(ConvertFrom-GeneratorBatch (Get-SuperBrainResponsesText $result.response) $batchCases $result.reportedModel)
      if ($batchAnswers.Count -ne $batchCases.Count) { Throw-GeneratorError 'ANSWER_RESPONSE_INVALID' 'Answer generator did not produce a valid batch response.' }
      $responseId = Get-SuperBrainResponsesId $result.response
      $batchIdReceipt = @($batchAnswers | Sort-Object id | ForEach-Object { [string]$_.id }) -join ','
      $batch.responseReceiptSha256 = Get-SuperBrainTextSha256 ($batchIdReceipt + "`n1`n" + $responseId + "`n" + $result.reportedModel)
      $batch.responseModel = $result.reportedModel
      $batch.status = 'complete'
      $batch.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
      $completed = New-Object Collections.ArrayList
      foreach ($existing in @($checkpoint.completedAnswers)) { [void]$completed.Add($existing) }
      foreach ($answerCase in $batchAnswers) { [void]$completed.Add($answerCase) }
      $checkpoint.completedAnswers = @($completed)
      Write-Phase6GenerationCheckpoint $checkpointPath $checkpoint
      $newBatchCount++
    } catch {
      $parts = $_.Exception.Message -split '\|',2
      $batch.status = 'blocked'
      $batch.errorCode = if ($parts.Count -eq 2) { [string]$parts[0] } else { 'PHASE6_BATCH_FAILED' }
      $batch.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
      $checkpoint.status = 'blocked'
      Write-Phase6GenerationCheckpoint $checkpointPath $checkpoint
      throw
    }
  }
  if (@($checkpoint.batches | Where-Object { [string]$_.status -ne 'complete' }).Count -gt 0) { Throw-GeneratorError 'PHASE6_CHECKPOINT_INCOMPLETE' 'Checkpoint did not complete every batch.' }
  $checkpoint.status = 'complete'
  Write-Phase6GenerationCheckpoint $checkpointPath $checkpoint
  $answerCases = Get-Phase6AnswerCasesFromCheckpoint $answerInput $checkpoint
  $receiptParts = @($checkpoint.batches | Sort-Object index | ForEach-Object { ([string]$_.index) + "`n" + ([string]$_.caseSetSha256) + "`n" + ([string]$_.responseReceiptSha256) })
  $responseReceipt = Get-SuperBrainTextSha256 (([string]$preflight.inputHash) + "`n" + $metadata.endpointHash + "`n" + ($receiptParts -join "`n"))
  $totalAttempts = @($checkpoint.batches | Measure-Object -Property attemptCount -Sum).Sum
  $artifact = [pscustomobject]@{
    schema = 'super-brain.memory-e2e-answer-artifact.v1'
    setHash = [string]$answerInput.setHash
    provenance = [pscustomobject]@{
      schema = 'super-brain.memory-e2e-answer-provenance.v2'
      kind = 'external_blinded_input'
      generatorId = 'super-brain.phase6-answer-artifact-generator'
      generatorVersion = $metadata.scriptHash
      generatorSha256 = $metadata.scriptHash
      runId = 'phase6-generation-' + $responseReceipt.Substring(0,32)
      modelId = $Model
      modelVersion = $Model
      endpointSha256 = $metadata.endpointHash
      responseReceiptSha256 = $responseReceipt
      responseCount = @($checkpoint.batches).Count
      caseCount = @($answerCases).Count
      responseAttemptCount = $totalAttempts
      responseModelEvidenceSha256 = Get-Phase6ResponseModelEvidenceHash @($answerCases)
      transportProbeReceiptSha256 = $metadata.transportProbeReceiptSha256
      independentExecution = $true
      expectedAnswerDataAvailable = $false
      inputSchema = 'super-brain.memory-e2e-answer-input.v1'
      inputHash = [string]$preflight.inputHash
      rawResponseStored = $false
    }
    cases = @($answerCases)
  }
  Write-GeneratorJsonAtomic $output $artifact
  return [pscustomobject]@{
    ok = $true
    action = 'Generate'
    schema = 'super-brain.phase6-answer-generator-result.v1'
    status = 'generated_private_artifact'
    outputPath = $output
    outputSha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    checkpointPath = $checkpointPath
    checkpointSha256 = (Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash.ToLowerInvariant()
    inputHash = [string]$preflight.inputHash
    caseCount = @($answerCases).Count
    batchCount = @($checkpoint.batches).Count
    resumed = [bool]$Resume
    model = $Model
    reportedModelId = $Model
    modelIdentityVerified = $true
    endpointSource = $connection.endpointSource
    credentialSource = $connection.credentialSource
    transportProbeReceiptSha256 = $metadata.transportProbeReceiptSha256
    credentialStored = $false
    rawResponseStored = $false
  }
}

function Write-GeneratorResult($Value,[int]$ExitCode=0) {
  if ($Json) { $Value | ConvertTo-Json -Depth 20 }
  elseif ($Value.ok -eq $true) { Write-Host "PHASE6_ANSWER_GENERATOR action=$Action status=$($Value.status)" }
  else { Write-Host "PHASE6_ANSWER_GENERATOR_FAILED code=$($Value.code)" }
  exit $ExitCode
}

try {
  $result = switch ($Action) {
    'Status' { Get-GeneratorStatus }
    'Preflight' {
      $result = Get-AnswerInputPreflight $AnswerInputPath
      [pscustomobject]@{ ok=$true; action='Preflight'; schema='super-brain.phase6-answer-generator-preflight.v1'; status='preflight_ok'; setHash=[string]$result.setHash; inputHash=[string]$result.inputHash; caseCount=[int]$result.caseCount; privateArtifact=$true; rawExpectedDataStored=$false }
    }
    'Probe' { Invoke-GeneratorProbe }
    'ExportNative' { Export-Phase6NativeAgentBatch }
    'ImportNative' { Import-Phase6NativeAgentBatch }
    'Generate' { Invoke-AnswerArtifactGeneration }
  }
  Write-GeneratorResult $result 0
} catch {
  $parts = $_.Exception.Message -split '\|',2
  $code = if ($parts.Count -eq 2) { $parts[0] } else { 'PHASE6_ANSWER_GENERATOR_ERROR' }
  $message = if ($parts.Count -eq 2) { $parts[1] } else { 'Answer artifact generation failed.' }
  Write-GeneratorResult ([pscustomobject]@{ ok=$false; action=$Action; schema='super-brain.phase6-answer-generator-error.v1'; code=$code; error=$message; credentialStored=$false; rawResponseStored=$false }) 1
}
