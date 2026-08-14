[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Status','Prepare','Judge','Finalize','Probe','ExportNative','ImportNative')]
  [string]$Action = 'Status',
  [string]$BaselinePath = '',
  [string]$TreatmentPath = '',
  [string]$StatePath = '',
  [string]$ExpectedStateSha256 = '',
  [string]$JudgeInputPath = '',
  [string]$JudgeResultPath = '',
  [string]$OutputPath = '',
  [string]$JudgeModel = 'gpt-5.6-terra',
  [ValidateSet('low','medium','high','xhigh','max')]
  [string]$JudgeReasoningEffort = 'max',
  [string]$JudgeResponsesUrl = '',
  [string]$JudgeApiKeyEnv = 'SUPER_BRAIN_JUDGE_API_KEY',
  [ValidateRange(5,300)]
  [int]$TimeoutSeconds = 45,
  [ValidateRange(1,3)]
  [int]$JudgeProbeMaxAttempts = 3,
  [ValidateRange(0,10000)]
  [int]$JudgeProbeRetryDelayMilliseconds = 750,
  [string]$NativeManifestPath = '',
  [string]$NativeResponseDirectory = '',
  [ValidateRange(1,20)]
  [int]$NativeBatchSize = 5,
  [switch]$Apply,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\responses-api-bridge.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot

function Throw-RunnerError([string]$Code,[string]$Message) {
  throw [InvalidOperationException]::new("$Code|$Message")
}

function Read-RunnerJson([string]$Path,[string]$Code) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Throw-RunnerError $Code 'Required JSON artifact is missing.'
  }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Throw-RunnerError $Code 'Required JSON artifact is invalid.' }
}

function Get-TextSha256([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha.Dispose()
  }
}

function Get-ArtifactSha256([string]$Path,[string]$Code) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Throw-RunnerError $Code 'Required artifact file is missing.'
  }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
  catch { Throw-RunnerError $Code 'Required artifact cannot be hashed.' }
}

function Get-RequiredText($Object,[string]$Name,[string]$Code) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { Throw-RunnerError $Code "Missing field: $Name" }
  $value = [string]$Object.PSObject.Properties[$Name].Value
  if ([string]::IsNullOrWhiteSpace($value)) { Throw-RunnerError $Code "Empty field: $Name" }
  return $value
}

function Get-OptionalText($Object,[string]$Name) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return '' }
  return [string]$Object.PSObject.Properties[$Name].Value
}

function Get-RequiredBoolean($Object,[string]$Name,[string]$Code) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name] -or $Object.PSObject.Properties[$Name].Value -isnot [bool]) {
    Throw-RunnerError $Code "Boolean field required: $Name"
  }
  return [bool]$Object.PSObject.Properties[$Name].Value
}

function Get-RequiredInteger($Object,[string]$Name,[string]$Code) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { Throw-RunnerError $Code "Missing field: $Name" }
  $value = $Object.PSObject.Properties[$Name].Value
  if ($value -isnot [byte] -and $value -isnot [int16] -and $value -isnot [int32] -and $value -isnot [int64]) {
    Throw-RunnerError $Code "Integer field required: $Name"
  }
  return [int64]$value
}

function Get-NewOutputPath([string]$Path,[string]$Code) {
  if ([string]::IsNullOrWhiteSpace($Path)) { Throw-RunnerError $Code 'Output path is required.' }
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $fullPath) { Throw-RunnerError $Code 'Refusing to overwrite an existing output artifact.' }
  $parent = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  return $fullPath
}

function Write-RunnerJson([string]$Path,$Value) {
  Write-JsonUtf8NoBom $Path $Value 30
}

function Get-CaseShapeHash($Case) {
  $id = Get-RequiredText $Case 'id' 'ANSWER_CASE_INVALID'
  $prompt = Get-RequiredText $Case 'prompt' 'ANSWER_CASE_INVALID'
  $reference = Get-OptionalText $Case 'reference'
  $rubric = Get-OptionalText $Case 'rubric'
  return Get-TextSha256 ($id + "`n" + $prompt + "`n" + $reference + "`n" + $rubric)
}

function Get-ResponseModelEvidenceHash($Cases) {
  $parts = @($Cases.Keys | Sort-Object | ForEach-Object {
    $case = $Cases[$_]
    ([string]$case.id) + "`n" + ([string]$case.responseModel)
  })
  return Get-TextSha256 ($parts -join "`n")
}

function Get-CaseSetHash($Cases) {
  $parts = @($Cases.Keys | Sort-Object | ForEach-Object {
    $case = $Cases[$_]
    ([string]$case.id) + "`n" + ([string]$case.shapeHash)
  })
  return Get-TextSha256 ($parts -join "`n")
}

function Get-AnswerArtifact([string]$Path,[bool]$ExpectedSuperBrainEnabled,[string]$Role) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $value = Read-RunnerJson $fullPath 'ANSWER_ARTIFACT_INVALID'
  if ([string]$value.schema -ne 'super-brain.objective-answer-artifact.v1') {
    Throw-RunnerError 'ANSWER_ARTIFACT_SCHEMA_INVALID' "$Role answer artifact schema is unsupported."
  }
  $caseSetHash = Get-RequiredText $value 'caseSetHash' 'ANSWER_ARTIFACT_INVALID'
  if ($null -eq $value.PSObject.Properties['generator']) { Throw-RunnerError 'ANSWER_GENERATOR_MISSING' "$Role generator provenance is missing." }
  $generator = $value.generator
  foreach ($field in @(
    'runId','executionId','modelId','modelVersion','requestedModelId','reportedModelId',
    'benchmarkVariant',
    'toolchainHash','budgetHash','environmentHash','promptTemplateHash','packageVersion',
    'subjectHash','packageManifestSha256','brainCoreSha256','memoryPolicySha256',
    'corpusHash','harnessHash','selectionSha256','pairContractSha256','configFingerprint','responseModelEvidenceSha256'
  )) {
    [void](Get-RequiredText $generator $field 'ANSWER_GENERATOR_INVALID')
  }
  $responseCount = Get-RequiredInteger $generator 'responseCount' 'ANSWER_GENERATOR_INVALID'
  $pairContractSha256 = Get-RequiredText $generator 'pairContractSha256' 'ANSWER_GENERATOR_INVALID'
  if ($pairContractSha256 -notmatch '^[a-fA-F0-9]{64}$') { Throw-RunnerError 'ANSWER_PAIR_CONTRACT_INVALID' "$Role pair contract hash is invalid." }
  if (
    [string]$generator.modelId -ne [string]$generator.requestedModelId -or
    [string]$generator.modelVersion -ne [string]$generator.reportedModelId -or
    [string]$generator.requestedModelId -ne [string]$generator.reportedModelId
  ) {
    Throw-RunnerError 'ANSWER_MODEL_IDENTITY_INVALID' "$Role requested/reported model identity is internally inconsistent."
  }
  if ([string]$generator.benchmarkVariant -notin @('oracle','s_cleaned')) {
    Throw-RunnerError 'ANSWER_BENCHMARK_VARIANT_INVALID' "$Role benchmark variant is unsupported."
  }
  $manifest = Get-SuperBrainManifest $Root
  if ([string]$generator.packageVersion -ne [string]$manifest.version) {
    Throw-RunnerError 'ANSWER_PACKAGE_VERSION_MISMATCH' "$Role artifact is not bound to the current package version."
  }
  $currentHashes = [ordered]@{
    packageManifestSha256 = Get-ArtifactSha256 (Join-Path $Root 'manifest.json') 'ANSWER_PACKAGE_HASH_FAILED'
    brainCoreSha256 = Get-ArtifactSha256 (Join-Path $Root 'runtime\brain_core.py') 'ANSWER_PACKAGE_HASH_FAILED'
    memoryPolicySha256 = Get-ArtifactSha256 (Join-Path $Root 'memory-policy.json') 'ANSWER_PACKAGE_HASH_FAILED'
  }
  foreach ($field in @($currentHashes.Keys)) {
    if ([string]$generator.PSObject.Properties[$field].Value -ne [string]$currentHashes[$field]) {
      Throw-RunnerError 'ANSWER_PACKAGE_HASH_MISMATCH' "$Role artifact package evidence differs for $field."
    }
  }
  if (-not (Get-RequiredBoolean $generator 'independentExecution' 'ANSWER_GENERATOR_INVALID')) {
    Throw-RunnerError 'ANSWER_GENERATOR_NOT_INDEPENDENT' "$Role artifact does not declare an independent generator execution."
  }
  if ((Get-RequiredBoolean $generator 'superMemoryBrainEnabled' 'ANSWER_GENERATOR_INVALID') -ne $ExpectedSuperBrainEnabled) {
    Throw-RunnerError 'ANSWER_CONDITION_INVALID' "$Role artifact has the wrong superMemoryBrainEnabled condition."
  }

  $cases = @($value.cases)
  if ($cases.Count -lt 1) { Throw-RunnerError 'ANSWER_CASES_EMPTY' "$Role answer artifact has no cases." }
  $byId = @{}
  foreach ($case in $cases) {
    $id = Get-RequiredText $case 'id' 'ANSWER_CASE_INVALID'
    if ($byId.ContainsKey($id)) { Throw-RunnerError 'ANSWER_CASE_DUPLICATE' "Duplicate case id: $id" }
    $prompt = Get-RequiredText $case 'prompt' 'ANSWER_CASE_INVALID'
    $answer = Get-RequiredText $case 'answer' 'ANSWER_CASE_INVALID'
    $responseModel = Get-RequiredText $case 'responseModel' 'ANSWER_CASE_INVALID'
    if ($responseModel -ne [string]$generator.reportedModelId) {
      Throw-RunnerError 'ANSWER_RESPONSE_MODEL_MISMATCH' "$Role case $id was produced by an unexpected reported model."
    }
    $byId[$id] = [pscustomobject]@{
      id = $id
      prompt = $prompt
      reference = Get-OptionalText $case 'reference'
      rubric = Get-OptionalText $case 'rubric'
      answer = $answer
      responseModel = $responseModel
      shapeHash = Get-CaseShapeHash $case
      answerSha256 = Get-TextSha256 $answer
    }
  }
  if ($responseCount -ne $byId.Count) { Throw-RunnerError 'ANSWER_RESPONSE_COUNT_MISMATCH' "$Role responseCount does not match its case count." }
  $computedCaseSetHash = Get-CaseSetHash $byId
  if ($computedCaseSetHash -ne $caseSetHash) {
    Throw-RunnerError 'ANSWER_CASE_SET_HASH_MISMATCH' "$Role caseSetHash does not match its actual case content."
  }
  $responseModelEvidenceHash = Get-ResponseModelEvidenceHash $byId
  if ($responseModelEvidenceHash -ne [string]$generator.responseModelEvidenceSha256) {
    Throw-RunnerError 'ANSWER_MODEL_EVIDENCE_MISMATCH' "$Role response-model evidence hash is invalid."
  }

  return [pscustomobject]@{
    path = $fullPath
    sha256 = Get-ArtifactSha256 $fullPath 'ANSWER_ARTIFACT_HASH_FAILED'
    caseSetHash = $caseSetHash
    pairContractSha256 = $pairContractSha256.ToLowerInvariant()
    generator = $generator
    cases = $byId
  }
}

function Assert-ComparableAnswerArtifacts($Baseline,$Treatment) {
  if ([string]$Baseline.caseSetHash -ne [string]$Treatment.caseSetHash) {
    Throw-RunnerError 'CASE_SET_MISMATCH' 'Baseline and treatment artifacts use different case sets.'
  }
  foreach ($field in @(
    'modelId','modelVersion','requestedModelId','reportedModelId','benchmarkVariant','toolchainHash','budgetHash',
    'environmentHash','promptTemplateHash','packageVersion','subjectHash','packageManifestSha256',
    'brainCoreSha256','memoryPolicySha256','corpusHash','harnessHash','selectionSha256','pairContractSha256','configFingerprint'
  )) {
    if ([string]$Baseline.generator.PSObject.Properties[$field].Value -ne [string]$Treatment.generator.PSObject.Properties[$field].Value) {
      Throw-RunnerError 'GENERATOR_CONDITIONS_MISMATCH' "Generator provenance differs for $field."
    }
  }
  if ([string]$Baseline.generator.runId -eq [string]$Treatment.generator.runId -or [string]$Baseline.generator.executionId -eq [string]$Treatment.generator.executionId) {
    Throw-RunnerError 'GENERATOR_NOT_INDEPENDENT' 'Baseline and treatment must come from distinct generator runs and executions.'
  }
  if ($Baseline.cases.Count -ne $Treatment.cases.Count) { Throw-RunnerError 'CASE_SET_MISMATCH' 'Baseline and treatment case counts differ.' }
  foreach ($id in @($Baseline.cases.Keys)) {
    if (-not $Treatment.cases.ContainsKey($id)) { Throw-RunnerError 'CASE_SET_MISMATCH' "Treatment is missing case id: $id" }
    if ([string]$Baseline.cases[$id].shapeHash -ne [string]$Treatment.cases[$id].shapeHash) {
      Throw-RunnerError 'CASE_CONTENT_MISMATCH' "Baseline and treatment case content differs: $id"
    }
  }
}

function Get-EnvironmentValue([string]$Name) {
  foreach ($scope in @('Process','User','Machine')) {
    $value = [Environment]::GetEnvironmentVariable($Name,$scope)
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
  }
  return ''
}

function Get-ApiKey([string]$Name) {
  return Get-EnvironmentValue $Name
}

function Get-JudgeConnection {
  $connection = Resolve-SuperBrainResponsesConnection -ExplicitResponsesUrl $JudgeResponsesUrl -PrimaryResponsesUrlEnvironment 'SUPER_BRAIN_JUDGE_RESPONSES_URL' -ApiKeyEnvironment $JudgeApiKeyEnv
  if ([string]::IsNullOrWhiteSpace([string]$connection.responsesUrl)) {
    Throw-RunnerError 'JUDGE_URL_REQUIRED' 'Judge Responses URL is required.'
  }
  if ([string]::IsNullOrWhiteSpace([string]$connection.apiKey)) {
    Throw-RunnerError 'JUDGE_API_KEY_MISSING' "No credential is available in $JudgeApiKeyEnv."
  }
  return [pscustomobject]@{
    uri = [uri]$connection.responsesUrl
    apiKey = [string]$connection.apiKey
    endpointSource = [string]$connection.endpointSource
    credentialSource = [string]$connection.credentialSource
  }
}

function Get-SafeJudgeUri([string]$Url) {
  if ([string]::IsNullOrWhiteSpace($Url)) { Throw-RunnerError 'JUDGE_URL_REQUIRED' 'Judge Responses URL is required.' }
  try { $uri = [uri]$Url } catch { Throw-RunnerError 'JUDGE_URL_INVALID' 'Judge Responses URL is invalid.' }
  if (-not $uri.IsAbsoluteUri) { Throw-RunnerError 'JUDGE_URL_INVALID' 'Judge Responses URL must be absolute.' }
  $localHttp = $uri.Scheme -eq 'http' -and $uri.Host -in @('127.0.0.1','localhost','::1')
  if ($uri.Scheme -ne 'https' -and -not $localHttp) { Throw-RunnerError 'JUDGE_URL_INSECURE' 'Only HTTPS or loopback HTTP judge endpoints are allowed.' }
  return $uri
}

function ConvertFrom-JudgeEventStream([string]$Content) {
  if ([string]::IsNullOrWhiteSpace($Content)) { Throw-RunnerError 'JUDGE_RESPONSE_INVALID' 'Judge event stream is empty.' }
  $completed = $null
  foreach ($block in @([regex]::Split($Content,'\r?\n\r?\n'))) {
    if ([string]::IsNullOrWhiteSpace($block)) { continue }
    $eventName = ''
    $dataLines = New-Object Collections.ArrayList
    foreach ($line in @([regex]::Split($block,'\r?\n'))) {
      if ($line -match '^event:\s*(.+)$') { $eventName = $matches[1].Trim(); continue }
      if ($line -match '^data:\s?(.*)$') { [void]$dataLines.Add($matches[1]) }
    }
    if ($dataLines.Count -eq 0) { continue }
    $payload = (@($dataLines) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($payload) -or $payload -eq '[DONE]') { continue }
    try { $eventValue = $payload | ConvertFrom-Json }
    catch { Throw-RunnerError 'JUDGE_RESPONSE_INVALID' 'Judge event stream contains invalid JSON data.' }
    $eventType = if ($eventValue.PSObject.Properties['type']) { [string]$eventValue.type } else { $eventName }
    if ($eventName -eq 'response.completed' -or $eventType -eq 'response.completed') { $completed = $eventValue }
  }
  if (-not $completed) { Throw-RunnerError 'JUDGE_RESPONSE_INCOMPLETE' 'Judge event stream has no response.completed event.' }
  if ($completed.PSObject.Properties['response'] -and $completed.response) { return $completed.response }
  return $completed
}

function Invoke-JudgeRequest([uri]$Uri,[string]$ApiKey,[string]$Model,[string]$ReasoningEffort,[string]$Prompt,[int]$Timeout) {
  try {
    $result = Invoke-SuperBrainResponsesRequest -Uri $Uri -ApiKey $ApiKey -Model $Model -ReasoningEffort $ReasoningEffort -RequestInput $Prompt -MaxOutputTokens 256 -TimeoutSeconds $Timeout
    return $result.response
  } catch {
    $parts = $_.Exception.Message -split '\|',2
    $code = if ($parts.Count -eq 2) { [string]$parts[0] } else { '' }
    if ($code -eq 'RESPONSES_REPORTED_MODEL_MISMATCH') {
      Throw-RunnerError 'JUDGE_REPORTED_MODEL_MISMATCH' "Judge requested $Model but the endpoint reported another model."
    }
    if ($code -eq 'RESPONSES_REPORTED_MODEL_MISSING') { Throw-RunnerError 'JUDGE_REPORTED_MODEL_MISSING' 'Judge response does not report its actual model identity.' }
    $detail = if ([string]::IsNullOrWhiteSpace($code)) { 'unclassified' } else { $code }
    Throw-RunnerError 'JUDGE_API_FAILED' "Judge Responses request failed through the verified transport client: $detail."
  }
}

function Get-JudgeResponseModel($Response) {
  if ($null -ne $Response -and $null -ne $Response.PSObject.Properties['model'] -and -not [string]::IsNullOrWhiteSpace([string]$Response.model)) {
    return [string]$Response.model
  }
  if ($null -ne $Response -and $null -ne $Response.PSObject.Properties['response'] -and $null -ne $Response.response -and $null -ne $Response.response.PSObject.Properties['model'] -and -not [string]::IsNullOrWhiteSpace([string]$Response.response.model)) {
    return [string]$Response.response.model
  }
  Throw-RunnerError 'JUDGE_REPORTED_MODEL_MISSING' 'Judge response does not report its actual model identity.'
}

function Get-JudgeResponseText($Response) {
  if ($null -ne $Response.PSObject.Properties['output_text'] -and -not [string]::IsNullOrWhiteSpace([string]$Response.output_text)) { return [string]$Response.output_text }
  foreach ($output in @($Response.output)) {
    foreach ($content in @($output.content)) {
      if ($null -ne $content.PSObject.Properties['text']) {
        if ($content.text -is [string]) { return [string]$content.text }
        if ($null -ne $content.text.PSObject.Properties['value']) { return [string]$content.text.value }
      }
    }
  }
  foreach ($choice in @($Response.choices)) {
    if ($choice.message -and $choice.message.content) { return [string]$choice.message.content }
  }
  Throw-RunnerError 'JUDGE_RESPONSE_INVALID' 'Judge response contains no text output.'
}

function Get-JudgeDecisionFromText([string]$Text) {
  $clean = $Text.Trim()
  $clean = $clean -replace '^```(?:json)?\s*','' -replace '\s*```$',''
  try { $value = $clean | ConvertFrom-Json } catch { Throw-RunnerError 'JUDGE_RESPONSE_INVALID' 'Judge response is not valid JSON.' }
  $aPassed = Get-RequiredBoolean $value.candidateA 'passed' 'JUDGE_RESPONSE_INVALID'
  $bPassed = Get-RequiredBoolean $value.candidateB 'passed' 'JUDGE_RESPONSE_INVALID'
  return [pscustomobject]@{ candidateA=[pscustomobject]@{passed=$aPassed}; candidateB=[pscustomobject]@{passed=$bPassed}; responseSha256=(Get-TextSha256 $Text) }
}

function Get-JudgeModelEvidenceHash($Decisions) {
  $parts = @($Decisions.Keys | Sort-Object | ForEach-Object {
    $decision = $Decisions[$_]
    ([string]$decision.id) + "`n" + ([string]$decision.responseModel)
  })
  return Get-TextSha256 ($parts -join "`n")
}

function Get-NativeJudgeIdentity([string]$Value,[string]$Name) {
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 160 -or $text -notmatch '^[A-Za-z0-9._:-]+$') {
    Throw-RunnerError 'NATIVE_JUDGE_IDENTITY_INVALID' "Native judge $Name is invalid."
  }
  return $text
}

function Get-NativeJudgePrivateOutputPath([string]$Path,[string]$Code,[string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path)) { Throw-RunnerError $Code "A private $Label path is required." }
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $fullPath) { Throw-RunnerError $Code "Refusing to overwrite an existing $Label artifact." }
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $privateStatePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($privateStatePath,[StringComparison]::OrdinalIgnoreCase)) {
    Throw-RunnerError $Code "$Label artifacts inside the package must be under private-state."
  }
  $parent = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  return $fullPath
}

function Get-NativeJudgeExistingPrivatePath([string]$Path,[string]$Code,[string]$Label,[switch]$Directory) {
  $requiredType = if ($Directory) { 'Container' } else { 'Leaf' }
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType $requiredType)) {
    Throw-RunnerError $Code "Required $Label artifact is missing."
  }
  $fullPath = [IO.Path]::GetFullPath($Path)
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $privateStatePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($privateStatePath,[StringComparison]::OrdinalIgnoreCase)) {
    Throw-RunnerError $Code "$Label artifacts inside the package must be under private-state."
  }
  return $fullPath
}

function Get-NativeJudgeNewPrivateDirectory([string]$Path,[string]$Code) {
  $fullPath = Get-NativeJudgePrivateOutputPath $Path $Code 'native judge batch directory'
  New-Item -ItemType Directory -Path $fullPath -ErrorAction Stop | Out-Null
  return $fullPath
}

function Get-NativeJudgeFileName([int]$Index,[string]$Suffix) {
  return ('batch-{0:D4}{1}' -f $Index,$Suffix)
}

function Get-NativeJudgeInput([string]$Path) {
  $fullPath = Get-NativeJudgeExistingPrivatePath $Path 'NATIVE_JUDGE_INPUT_MISSING' 'blind judge input'
  $input = Read-RunnerJson $fullPath 'NATIVE_JUDGE_INPUT_INVALID'
  if ([string]$input.schema -ne 'super-brain.objective-blind-judge-input.v1') { Throw-RunnerError 'NATIVE_JUDGE_INPUT_SCHEMA_INVALID' 'Native judge input schema is unsupported.' }
  $inputHash = Get-ArtifactSha256 $fullPath 'NATIVE_JUDGE_INPUT_HASH_FAILED'
  $pairContractSha256 = (Get-RequiredText $input 'pairContractSha256' 'NATIVE_JUDGE_INPUT_INVALID').ToLowerInvariant()
  if ($pairContractSha256 -notmatch '^[a-f0-9]{64}$') { Throw-RunnerError 'NATIVE_JUDGE_INPUT_INVALID' 'Native judge input pair contract hash is invalid.' }
  $model = Get-RequiredText $input.judge 'modelId' 'NATIVE_JUDGE_INPUT_INVALID'
  $effort = Get-RequiredText $input.judge 'reasoningEffort' 'NATIVE_JUDGE_INPUT_INVALID'
  if ($model -ne $JudgeModel -or $effort -ne $JudgeReasoningEffort -or -not (Get-RequiredBoolean $input.judge 'independentExecution' 'NATIVE_JUDGE_INPUT_INVALID')) {
    Throw-RunnerError 'NATIVE_JUDGE_INPUT_BINDING_MISMATCH' 'Native judge input does not match the requested independent judge identity.'
  }
  $cases = @{}
  foreach ($case in @($input.cases)) {
    $id = Get-RequiredText $case 'id' 'NATIVE_JUDGE_INPUT_INVALID'
    if ($cases.ContainsKey($id)) { Throw-RunnerError 'NATIVE_JUDGE_INPUT_INVALID' "Native judge input has duplicate case id: $id" }
    foreach ($name in @($case.PSObject.Properties.Name)) {
      if ($name -match '(?i)baseline|treatment|condition') { Throw-RunnerError 'NATIVE_JUDGE_BLINDING_BROKEN' 'Native judge input contains an unblinded condition field.' }
    }
    $cases[$id] = [pscustomobject]@{
      id=$id
      prompt=Get-RequiredText $case 'prompt' 'NATIVE_JUDGE_INPUT_INVALID'
      reference=Get-RequiredText $case 'reference' 'NATIVE_JUDGE_INPUT_INVALID'
      rubric=Get-RequiredText $case 'rubric' 'NATIVE_JUDGE_INPUT_INVALID'
      candidateA=Get-RequiredText $case 'candidateA' 'NATIVE_JUDGE_INPUT_INVALID'
      candidateB=Get-RequiredText $case 'candidateB' 'NATIVE_JUDGE_INPUT_INVALID'
    }
  }
  if ($cases.Count -lt 1 -or (Get-RequiredInteger $input 'caseCount' 'NATIVE_JUDGE_INPUT_INVALID') -ne $cases.Count) { Throw-RunnerError 'NATIVE_JUDGE_INPUT_INVALID' 'Native judge input case count is invalid.' }
  return [pscustomobject]@{ path=$fullPath; inputHash=$inputHash; pairContractSha256=$pairContractSha256; model=$model; reasoningEffort=$effort; cases=$cases }
}

function ConvertTo-NativeJudgeCase($Case) {
  return [pscustomobject]([ordered]@{
    id=[string]$Case.id
    prompt=[string]$Case.prompt
    reference=[string]$Case.reference
    rubric=[string]$Case.rubric
    candidateA=[string]$Case.candidateA
    candidateB=[string]$Case.candidateB
  })
}

function Get-NativeJudgeBatchDescriptor($Batch) {
  return [ordered]@{
    schema=[string]$Batch.schema
    workflow=[string]$Batch.workflow
    manifestId=[string]$Batch.manifestId
    judgeInputSha256=[string]$Batch.judgeInputSha256
    pairContractSha256=[string]$Batch.pairContractSha256
    judgeModel=[string]$Batch.judgeModel
    judgeReasoningEffort=[string]$Batch.judgeReasoningEffort
    batchIndex=[int]$Batch.batchIndex
    responseFile=[string]$Batch.responseFile
    cases=@($Batch.cases)
    privacy=[ordered]@{ conditionLabelsSentToAgent=$Batch.privacy.conditionLabelsSentToAgent; rawJudgeTranscriptStored=$Batch.privacy.rawJudgeTranscriptStored }
  }
}

function Get-NativeJudgeBatchHash($Batch) {
  return Get-TextSha256 ((Get-NativeJudgeBatchDescriptor $Batch | ConvertTo-Json -Depth 24 -Compress))
}

function Get-NativeJudgeManifestDescriptor($Manifest) {
  return [ordered]@{
    schema=[string]$Manifest.schema
    workflow=[string]$Manifest.workflow
    manifestId=[string]$Manifest.manifestId
    judgeInputSha256=[string]$Manifest.judgeInputSha256
    pairContractSha256=[string]$Manifest.pairContractSha256
    judgeModel=[string]$Manifest.judgeModel
    judgeReasoningEffort=[string]$Manifest.judgeReasoningEffort
    batchSize=[int]$Manifest.batchSize
    batchCount=[int]$Manifest.batchCount
    batchDirectoryName=[string]$Manifest.batchDirectoryName
    batches=@($Manifest.batches | Sort-Object index | ForEach-Object { [ordered]@{ index=[int]$_.index; batchId=[string]$_.batchId; batchHash=[string]$_.batchHash; batchFile=[string]$_.batchFile; responseFile=[string]$_.responseFile; caseIds=@($_.caseIds) } })
    privacy=[ordered]@{ conditionLabelsSentToAgent=$Manifest.privacy.conditionLabelsSentToAgent; rawJudgeTranscriptStored=$Manifest.privacy.rawJudgeTranscriptStored }
  }
}

function Get-NativeJudgeManifestHash($Manifest) {
  return Get-TextSha256 ((Get-NativeJudgeManifestDescriptor $Manifest | ConvertTo-Json -Depth 24 -Compress))
}

function Assert-NativeJudgePrivacy($Privacy,[string]$Code) {
  if ($null -eq $Privacy) { Throw-RunnerError $Code 'Native judge privacy contract is missing.' }
  $allowed = @('conditionLabelsSentToAgent','rawJudgeTranscriptStored')
  $actual = @($Privacy.PSObject.Properties.Name)
  if (@($actual | Where-Object { $_ -notin $allowed }).Count -gt 0 -or @($allowed | Where-Object { $_ -notin $actual }).Count -gt 0 -or
      (Get-RequiredBoolean $Privacy 'conditionLabelsSentToAgent' $Code) -ne $false -or (Get-RequiredBoolean $Privacy 'rawJudgeTranscriptStored' $Code) -ne $false) {
    Throw-RunnerError $Code 'Native judge privacy contract is invalid.'
  }
}

function Assert-NativeJudgeManifest($Manifest,$JudgeInput) {
  if ($null -eq $Manifest) { Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_INVALID' 'Native judge manifest is missing.' }
  $allowed = @('schema','workflow','manifestId','judgeInputSha256','pairContractSha256','judgeModel','judgeReasoningEffort','batchSize','batchCount','batchDirectoryName','batches','manifestHash','privacy')
  $actual = @($Manifest.PSObject.Properties.Name)
  if (@($actual | Where-Object { $_ -notin $allowed }).Count -gt 0 -or @($allowed | Where-Object { $_ -notin $actual }).Count -gt 0 -or
      [string]$Manifest.schema -ne 'super-brain.objective-native-judge-manifest.v1' -or [string]$Manifest.workflow -ne 'longmemeval_s_cleaned_blind_judge') {
    Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_INVALID' 'Native judge manifest schema is invalid.'
  }
  $manifestId = Get-NativeJudgeIdentity ([string]$Manifest.manifestId) 'manifest id'
  if ([string]$Manifest.judgeInputSha256 -ne [string]$JudgeInput.inputHash) { Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_INPUT_MISMATCH' 'Native judge manifest does not bind the current blind input.' }
  if ([string]$Manifest.pairContractSha256 -ne [string]$JudgeInput.pairContractSha256) { Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_CONTRACT_MISMATCH' 'Native judge manifest does not bind the current pair contract.' }
  if ([string]$Manifest.judgeModel -ne [string]$JudgeInput.model -or [string]$Manifest.judgeReasoningEffort -ne [string]$JudgeInput.reasoningEffort) { Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_IDENTITY_MISMATCH' 'Native judge manifest does not bind the current judge identity.' }
  if ([int]$Manifest.batchSize -ne $NativeBatchSize) { Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_BATCH_SIZE_MISMATCH' 'Native judge manifest batch size does not match the requested import/export size.' }
  Assert-NativeJudgePrivacy $Manifest.privacy 'NATIVE_JUDGE_MANIFEST_INVALID'
  $directoryName = Get-RequiredText $Manifest 'batchDirectoryName' 'NATIVE_JUDGE_MANIFEST_INVALID'
  if ([IO.Path]::GetFileName($directoryName) -ne $directoryName) { Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_INVALID' 'Native judge batch directory name is invalid.' }
  $orderedCases = @($JudgeInput.cases.Values | Sort-Object id)
  $expectedCount = [int][Math]::Ceiling($orderedCases.Count / [double]$NativeBatchSize)
  if ([int]$Manifest.batchCount -ne $expectedCount -or @($Manifest.batches).Count -ne $expectedCount -or [string]$Manifest.manifestHash -ne (Get-NativeJudgeManifestHash $Manifest)) {
    Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_INVALID' 'Native judge manifest count or hash is invalid.'
  }
  for ($index = 0; $index -lt $expectedCount; $index++) {
    $entry = @($Manifest.batches | Where-Object { [int]$_.index -eq $index })
    if ($entry.Count -ne 1) { Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_INVALID' 'Native judge manifest batch indexes are invalid.' }
    $entry = $entry[0]
    $allowedEntry = @('index','batchId','batchHash','batchFile','responseFile','caseIds')
    $actualEntry = @($entry.PSObject.Properties.Name)
    if (@($actualEntry | Where-Object { $_ -notin $allowedEntry }).Count -gt 0 -or @($allowedEntry | Where-Object { $_ -notin $actualEntry }).Count -gt 0 -or
        [string]$entry.batchId -ne ($manifestId + ':' + $index) -or [string]$entry.batchHash -notmatch '^[a-f0-9]{64}$' -or
        [string]$entry.batchFile -ne (Get-NativeJudgeFileName $index '.json') -or [string]$entry.responseFile -ne (Get-NativeJudgeFileName $index '.response.json')) {
      Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_INVALID' 'Native judge batch entry is invalid.'
    }
    $offset = $index * $NativeBatchSize
    $last = [Math]::Min($offset + $NativeBatchSize - 1,$orderedCases.Count - 1)
    $expectedIds = @($orderedCases[$offset..$last] | ForEach-Object { [string]$_.id })
    if ((@($entry.caseIds) -join "`n") -ne ($expectedIds -join "`n")) { Throw-RunnerError 'NATIVE_JUDGE_MANIFEST_INVALID' 'Native judge manifest case layout is invalid.' }
  }
  return $Manifest
}

function Assert-NativeJudgeBatch($Batch,$Entry,$ExpectedCases,$JudgeInput,$Manifest) {
  if ($null -eq $Batch) { Throw-RunnerError 'NATIVE_JUDGE_BATCH_INVALID' 'Native judge batch is missing.' }
  $allowed = @('schema','workflow','manifestId','judgeInputSha256','pairContractSha256','judgeModel','judgeReasoningEffort','batchIndex','responseFile','cases','batchHash','privacy')
  $actual = @($Batch.PSObject.Properties.Name)
  if (@($actual | Where-Object { $_ -notin $allowed }).Count -gt 0 -or @($allowed | Where-Object { $_ -notin $actual }).Count -gt 0 -or
      [string]$Batch.schema -ne 'super-brain.objective-native-judge-batch.v1' -or [string]$Batch.workflow -ne 'longmemeval_s_cleaned_blind_judge' -or
      [string]$Batch.manifestId -ne [string]$Manifest.manifestId -or [string]$Batch.judgeInputSha256 -ne [string]$JudgeInput.inputHash -or
      [string]$Batch.pairContractSha256 -ne [string]$JudgeInput.pairContractSha256 -or [string]$Batch.judgeModel -ne [string]$JudgeInput.model -or
      [string]$Batch.judgeReasoningEffort -ne [string]$JudgeInput.reasoningEffort -or [int]$Batch.batchIndex -ne [int]$Entry.index -or
      [string]$Batch.responseFile -ne [string]$Entry.responseFile -or [string]$Batch.batchHash -ne [string]$Entry.batchHash -or [string]$Batch.batchHash -ne (Get-NativeJudgeBatchHash $Batch)) {
    Throw-RunnerError 'NATIVE_JUDGE_BATCH_INVALID' 'Native judge batch binding or hash is invalid.'
  }
  Assert-NativeJudgePrivacy $Batch.privacy 'NATIVE_JUDGE_BATCH_INVALID'
  $expectedProjection = @($ExpectedCases | ForEach-Object { ConvertTo-NativeJudgeCase $_ } | Sort-Object id)
  $actualCases = @($Batch.cases | Sort-Object id)
  if ($actualCases.Count -ne $expectedProjection.Count) { Throw-RunnerError 'NATIVE_JUDGE_BATCH_INVALID' 'Native judge batch case coverage is invalid.' }
  for ($index = 0; $index -lt $expectedProjection.Count; $index++) {
    $case = $actualCases[$index]
    foreach ($name in @($case.PSObject.Properties.Name)) { if ($name -match '(?i)baseline|treatment|condition') { Throw-RunnerError 'NATIVE_JUDGE_BLINDING_BROKEN' 'Native judge batch contains an unblinded condition field.' } }
    if (($expectedProjection[$index] | ConvertTo-Json -Depth 16 -Compress) -ne ($case | ConvertTo-Json -Depth 16 -Compress)) { Throw-RunnerError 'NATIVE_JUDGE_BATCH_INVALID' 'Native judge batch contains data outside the blinded judge input.' }
  }
}

function Read-NativeJudgeResponse($Response,$Batch,$ExpectedCases) {
  if ($null -eq $Response) { Throw-RunnerError 'NATIVE_JUDGE_RESPONSE_INVALID' 'Native judge response is missing.' }
  $allowed = @('schema','batchId','batchHash','hostAgentId','hostDispatchId','decisions')
  $actual = @($Response.PSObject.Properties.Name)
  if (@($actual | Where-Object { $_ -notin $allowed }).Count -gt 0 -or @($allowed | Where-Object { $_ -notin $actual }).Count -gt 0 -or
      [string]$Response.schema -ne 'super-brain.objective-host-native-judge-response.v1' -or [string]$Response.batchId -ne (([string]$Batch.manifestId) + ':' + ([string]$Batch.batchIndex)) -or
      [string]$Response.batchHash -ne [string]$Batch.batchHash) {
    Throw-RunnerError 'NATIVE_JUDGE_RESPONSE_INVALID' 'Native judge response must contain only one bound blinded decision payload.'
  }
  $expected = @{}
  foreach ($case in $ExpectedCases) { $expected[[string]$case.id] = $true }
  $decisions = @{}
  foreach ($item in @($Response.decisions)) {
    foreach ($name in @($item.PSObject.Properties.Name)) { if ($name -match '(?i)baseline|treatment|condition') { Throw-RunnerError 'NATIVE_JUDGE_BLINDING_BROKEN' 'Native judge decision contains an unblinded condition field.' } }
    $id = Get-RequiredText $item 'id' 'NATIVE_JUDGE_RESPONSE_INVALID'
    if ($decisions.ContainsKey($id) -or -not $expected.ContainsKey($id)) { Throw-RunnerError 'NATIVE_JUDGE_RESPONSE_INVALID' 'Native judge response decision ids are invalid.' }
    $candidateA = [pscustomobject]@{ passed=(Get-RequiredBoolean $item.candidateA 'passed' 'NATIVE_JUDGE_RESPONSE_INVALID') }
    $candidateB = [pscustomobject]@{ passed=(Get-RequiredBoolean $item.candidateB 'passed' 'NATIVE_JUDGE_RESPONSE_INVALID') }
    $decisionText = ([pscustomobject]@{ id=$id; candidateA=$candidateA; candidateB=$candidateB } | ConvertTo-Json -Depth 8 -Compress)
    $decisions[$id] = [pscustomobject]@{ id=$id; candidateA=$candidateA; candidateB=$candidateB; responseSha256=(Get-TextSha256 $decisionText); responseModel=[string]$Batch.judgeModel }
  }
  if ($decisions.Count -ne $expected.Count) { Throw-RunnerError 'NATIVE_JUDGE_RESPONSE_INVALID' 'Native judge response does not cover every batch case exactly once.' }
  return [pscustomobject]@{ decisions=@($decisions.Keys | Sort-Object | ForEach-Object { $decisions[$_] }); hostAgentId=(Get-NativeJudgeIdentity ([string]$Response.hostAgentId) 'id'); hostDispatchId=(Get-NativeJudgeIdentity ([string]$Response.hostDispatchId) 'dispatch id') }
}

function Export-NativeJudgeBatches {
  if (-not $Apply) { Throw-RunnerError 'NATIVE_JUDGE_EXPORT_APPLY_REQUIRED' 'Native judge batch export requires explicit -Apply.' }
  $input = Get-NativeJudgeInput $JudgeInputPath
  $manifestPath = Get-NativeJudgePrivateOutputPath $NativeManifestPath 'NATIVE_JUDGE_MANIFEST_OUTPUT_INVALID' 'native judge manifest'
  $batchDirectoryName = [IO.Path]::GetFileName($manifestPath) + '.batches'
  $batchDirectory = Get-NativeJudgeNewPrivateDirectory (Join-Path (Split-Path -Parent $manifestPath) $batchDirectoryName) 'NATIVE_JUDGE_BATCH_DIRECTORY_EXISTS'
  $orderedCases = @($input.cases.Values | Sort-Object id)
  $manifestId = 'native-judge-' + [guid]::NewGuid().ToString('N')
  $entries = New-Object Collections.ArrayList
  $batchIndex = 0
  for ($offset = 0; $offset -lt $orderedCases.Count; $offset += $NativeBatchSize) {
    $last = [Math]::Min($offset + $NativeBatchSize - 1,$orderedCases.Count - 1)
    $batchCases = @($orderedCases[$offset..$last])
    $batchFile = Get-NativeJudgeFileName $batchIndex '.json'
    $responseFile = Get-NativeJudgeFileName $batchIndex '.response.json'
    $batch = [pscustomobject]([ordered]@{
      schema='super-brain.objective-native-judge-batch.v1'; workflow='longmemeval_s_cleaned_blind_judge'; manifestId=$manifestId
      judgeInputSha256=$input.inputHash; pairContractSha256=$input.pairContractSha256; judgeModel=$input.model; judgeReasoningEffort=$input.reasoningEffort
      batchIndex=$batchIndex; responseFile=$responseFile; cases=@($batchCases | ForEach-Object { ConvertTo-NativeJudgeCase $_ }); batchHash=''
      privacy=[pscustomobject]@{ conditionLabelsSentToAgent=$false; rawJudgeTranscriptStored=$false }
    })
    $batch.batchHash = Get-NativeJudgeBatchHash $batch
    Write-RunnerJson (Join-Path $batchDirectory $batchFile) $batch
    [void]$entries.Add([pscustomobject]([ordered]@{ index=$batchIndex; batchId=$manifestId + ':' + $batchIndex; batchHash=$batch.batchHash; batchFile=$batchFile; responseFile=$responseFile; caseIds=@($batchCases | ForEach-Object { [string]$_.id }) }))
    $batchIndex++
  }
  $manifest = [pscustomobject]([ordered]@{
    schema='super-brain.objective-native-judge-manifest.v1'; workflow='longmemeval_s_cleaned_blind_judge'; manifestId=$manifestId
    judgeInputSha256=$input.inputHash; pairContractSha256=$input.pairContractSha256; judgeModel=$input.model; judgeReasoningEffort=$input.reasoningEffort
    batchSize=$NativeBatchSize; batchCount=$entries.Count; batchDirectoryName=$batchDirectoryName; batches=@($entries); manifestHash=''
    privacy=[pscustomobject]@{ conditionLabelsSentToAgent=$false; rawJudgeTranscriptStored=$false }
  })
  $manifest.manifestHash = Get-NativeJudgeManifestHash $manifest
  [void](Assert-NativeJudgeManifest $manifest $input)
  Write-RunnerJson $manifestPath $manifest
  return [pscustomobject]@{ ok=$true; action='ExportNative'; schema='super-brain.objective-native-judge-export-result.v1'; status='native_judge_batches_exported_private'; nativeManifestPath=$manifestPath; nativeManifestSha256=(Get-ArtifactSha256 $manifestPath 'NATIVE_JUDGE_MANIFEST_HASH_FAILED'); batchDirectory=$batchDirectory; manifestId=$manifestId; batchCount=$entries.Count; caseCount=$orderedCases.Count; judgeModel=$input.model; judgeReasoningEffort=$input.reasoningEffort; conditionLabelsSentToAgent=$false; rawJudgeTranscriptStored=$false }
}

function Import-NativeJudgeBatches {
  if (-not $Apply) { Throw-RunnerError 'NATIVE_JUDGE_IMPORT_APPLY_REQUIRED' 'Native judge batch import requires explicit -Apply.' }
  $input = Get-NativeJudgeInput $JudgeInputPath
  $manifestPath = Get-NativeJudgeExistingPrivatePath $NativeManifestPath 'NATIVE_JUDGE_MANIFEST_MISSING' 'native judge manifest'
  $responseDirectory = Get-NativeJudgeExistingPrivatePath $NativeResponseDirectory 'NATIVE_JUDGE_RESPONSE_DIRECTORY_MISSING' 'native judge response' -Directory
  $resultPath = Get-NativeJudgePrivateOutputPath $JudgeResultPath 'NATIVE_JUDGE_RESULT_OUTPUT_INVALID' 'native judge result'
  $manifest = Read-RunnerJson $manifestPath 'NATIVE_JUDGE_MANIFEST_INVALID'
  [void](Assert-NativeJudgeManifest $manifest $input)
  $batchDirectory = Get-NativeJudgeExistingPrivatePath (Join-Path (Split-Path -Parent $manifestPath) ([string]$manifest.batchDirectoryName)) 'NATIVE_JUDGE_BATCH_DIRECTORY_MISSING' 'native judge batch' -Directory
  $orderedCases = @($input.cases.Values | Sort-Object id)
  $decisionMap = @{}
  $receiptHashes = New-Object Collections.ArrayList
  $dispatchIds = @{}
  foreach ($entry in @($manifest.batches | Sort-Object index)) {
    $index = [int]$entry.index
    $offset = $index * $NativeBatchSize
    $last = [Math]::Min($offset + $NativeBatchSize - 1,$orderedCases.Count - 1)
    $expectedCases = @($orderedCases[$offset..$last])
    $batchPath = Get-NativeJudgeExistingPrivatePath (Join-Path $batchDirectory ([string]$entry.batchFile)) 'NATIVE_JUDGE_BATCH_MISSING' 'native judge batch'
    $batch = Read-RunnerJson $batchPath 'NATIVE_JUDGE_BATCH_INVALID'
    Assert-NativeJudgeBatch $batch $entry $expectedCases $input $manifest
    $responsePath = Get-NativeJudgeExistingPrivatePath (Join-Path $responseDirectory ([string]$entry.responseFile)) 'NATIVE_JUDGE_RESPONSE_MISSING' 'native judge response'
    $response = Read-RunnerJson $responsePath 'NATIVE_JUDGE_RESPONSE_INVALID'
    $nativeResponse = Read-NativeJudgeResponse $response $batch $expectedCases
    $dispatchKey = $nativeResponse.hostAgentId + "`n" + $nativeResponse.hostDispatchId
    if ($dispatchIds.ContainsKey($dispatchKey)) { Throw-RunnerError 'NATIVE_JUDGE_DISPATCH_DUPLICATE' 'A host-native judge dispatch may decide only one blinded batch.' }
    $dispatchIds[$dispatchKey] = $true
    foreach ($decision in @($nativeResponse.decisions)) {
      if ($decisionMap.ContainsKey([string]$decision.id)) { Throw-RunnerError 'NATIVE_JUDGE_RESPONSE_INVALID' 'Native judge responses contain duplicate decision ids.' }
      $decisionMap[[string]$decision.id] = $decision
    }
    $receipt = [ordered]@{ schema='super-brain.objective-native-judge-dispatch-receipt.v1'; manifestId=$manifest.manifestId; batchId=$entry.batchId; batchHash=$entry.batchHash; hostAgentId=$nativeResponse.hostAgentId; hostDispatchId=$nativeResponse.hostDispatchId; responseSha256=(Get-ArtifactSha256 $responsePath 'NATIVE_JUDGE_RESPONSE_HASH_FAILED'); decisionCount=@($nativeResponse.decisions).Count; conditionLabelsSentToAgent=$false; rawJudgeTranscriptStored=$false }
    [void]$receiptHashes.Add((Get-TextSha256 ($receipt | ConvertTo-Json -Depth 16 -Compress)))
  }
  if ($decisionMap.Count -ne $orderedCases.Count) { Throw-RunnerError 'NATIVE_JUDGE_RESPONSE_INVALID' 'Native judge responses do not cover every blinded case.' }
  $dispatchReceipt = Get-TextSha256 ((@($receiptHashes) | Sort-Object) -join "`n")
  $nativeHostHash = Get-TextSha256 'codex-desktop-native-agent-host-v1'
  $decisions = @($decisionMap.Keys | Sort-Object | ForEach-Object { $decisionMap[$_] })
  $result = [pscustomobject]@{
    schema='super-brain.objective-blind-judge-result.v1'; status='completed'; createdAt=(Get-Date).ToString('o'); judgeInputSha256=$input.inputHash; pairContractSha256=$input.pairContractSha256
    judge=[pscustomobject]@{ modelId=$input.model; reportedModelId=$input.model; modelIdentityVerified=$true; reasoningEffort=$input.reasoningEffort; judgeRunId='native-judge-' + $dispatchReceipt.Substring(0,32); independentExecution=$true; endpointSha256=$nativeHostHash; transportProbeReceiptSha256=''; responseCount=$decisions.Count; responseModelEvidenceSha256=(Get-JudgeModelEvidenceHash $decisionMap); hostedNativeAgent=$true; nativeManifestSha256=$manifest.manifestHash; hostDispatchReceiptSha256=$dispatchReceipt; hostDispatchCount=@($manifest.batches).Count }
    decisions=$decisions; rawJudgeResponseStored=$false
  }
  Write-RunnerJson $resultPath $result
  return [pscustomobject]@{ ok=$true; action='ImportNative'; schema='super-brain.objective-native-judge-import-result.v1'; status='native_judge_result_imported_private'; judgeResultPath=$resultPath; judgeResultSha256=(Get-ArtifactSha256 $resultPath 'NATIVE_JUDGE_RESULT_HASH_FAILED'); nativeManifestSha256=$manifest.manifestHash; hostDispatchReceiptSha256=$dispatchReceipt; batchCount=@($manifest.batches).Count; caseCount=$decisions.Count; judgeModel=$input.model; judgeReasoningEffort=$input.reasoningEffort; modelIdentityVerified=$true; conditionLabelsSentToAgent=$false; rawJudgeTranscriptStored=$false }
}

function New-PreparedRun {
  $baseline = Get-AnswerArtifact $BaselinePath $false 'Baseline'
  $treatment = Get-AnswerArtifact $TreatmentPath $true 'Treatment'
  Assert-ComparableAnswerArtifacts $baseline $treatment
  $stateOutput = Get-NewOutputPath $StatePath 'STATE_OUTPUT_INVALID'
  $judgeInputOutput = Get-NewOutputPath $JudgeInputPath 'JUDGE_INPUT_OUTPUT_INVALID'
  if ($stateOutput -eq $judgeInputOutput) { Throw-RunnerError 'OUTPUT_PATH_COLLISION' 'State and blinded judge input paths must differ.' }
  $assignmentSeed = [guid]::NewGuid().ToString('N')
  $judgeCases = New-Object Collections.ArrayList
  $pairings = New-Object Collections.ArrayList
  foreach ($id in @($baseline.cases.Keys | Sort-Object)) {
    $base = $baseline.cases[$id]
    $treat = $treatment.cases[$id]
    $selector = [Convert]::ToInt32((Get-TextSha256 ($assignmentSeed + "`n" + $id)).Substring(0,2),16)
    $baseIsA = (($selector % 2) -eq 0)
    $candidateA = if ($baseIsA) { [string]$base.answer } else { [string]$treat.answer }
    $candidateB = if ($baseIsA) { [string]$treat.answer } else { [string]$base.answer }
    [void]$judgeCases.Add([pscustomobject]@{
      id = $id
      prompt = [string]$base.prompt
      reference = [string]$base.reference
      rubric = [string]$base.rubric
      candidateA = $candidateA
      candidateB = $candidateB
    })
    [void]$pairings.Add([pscustomobject]@{
      id = $id
      candidateACondition = if ($baseIsA) { 'baseline' } else { 'treatment' }
      candidateBCondition = if ($baseIsA) { 'treatment' } else { 'baseline' }
      baselineAnswerSha256 = [string]$base.answerSha256
      treatmentAnswerSha256 = [string]$treat.answerSha256
      caseShapeSha256 = [string]$base.shapeHash
    })
  }
  $rubric = 'Independently judge candidate A and candidate B against the task, reference, and rubric. Return only JSON with Boolean candidateA.passed and candidateB.passed. Do not infer labels or system conditions.'
  $judgeInput = [pscustomobject]@{
    schema = 'super-brain.objective-blind-judge-input.v1'
    judgeRequestId = 'objective-judge-' + [guid]::NewGuid().ToString('N')
    createdAt = (Get-Date).ToString('o')
    caseSetHash = [string]$baseline.caseSetHash
    pairContractSha256 = [string]$baseline.pairContractSha256
    caseCount = $judgeCases.Count
    judge = [pscustomobject]@{ modelId=$JudgeModel; reasoningEffort=$JudgeReasoningEffort; independentExecution=$true }
    rubric = $rubric
    rubricSha256 = Get-TextSha256 $rubric
    cases = @($judgeCases)
  }
  Write-RunnerJson $judgeInputOutput $judgeInput
  $judgeInputHash = Get-ArtifactSha256 $judgeInputOutput 'JUDGE_INPUT_HASH_FAILED'
  $state = [pscustomobject]@{
    schema = 'super-brain.objective-blind-run-state.v1'
    stateId = 'objective-blind-' + [guid]::NewGuid().ToString('N')
    status = 'awaiting_judge'
    createdAt = (Get-Date).ToString('o')
    packageVersion = [string](Get-SuperBrainManifest $Root).version
    benchmarkVariant = [string]$baseline.generator.benchmarkVariant
    caseSetHash = [string]$baseline.caseSetHash
    pairContractSha256 = [string]$baseline.pairContractSha256
    caseCount = $judgeCases.Count
    assignmentSeedSha256 = Get-TextSha256 $assignmentSeed
    baselineArtifact = [pscustomobject]@{ path=$baseline.path; sha256=$baseline.sha256; generator=$baseline.generator }
    treatmentArtifact = [pscustomobject]@{ path=$treatment.path; sha256=$treatment.sha256; generator=$treatment.generator }
    judge = [pscustomobject]@{ modelId=$JudgeModel; reasoningEffort=$JudgeReasoningEffort; independentExecution=$true }
    judgeInput = [pscustomobject]@{ path=$judgeInputOutput; sha256=$judgeInputHash; rubricSha256=$judgeInput.rubricSha256 }
    pairings = @($pairings)
    finalizedAt = ''
    judgeResult = $null
    rawAnswersStored = $false
    rawJudgeResponseStored = $false
  }
  Write-RunnerJson $stateOutput $state
  return [pscustomobject]@{
    ok = $true
    action = 'Prepare'
    schema = 'super-brain.objective-blind-run-prepared.v1'
    status = 'awaiting_judge'
    statePath = $stateOutput
    stateSha256 = Get-ArtifactSha256 $stateOutput 'STATE_HASH_FAILED'
    judgeInputPath = $judgeInputOutput
    judgeInputSha256 = $judgeInputHash
    caseCount = $judgeCases.Count
    pairContractSha256 = [string]$baseline.pairContractSha256
    judgeModel = $JudgeModel
    judgeReasoningEffort = $JudgeReasoningEffort
    publicationStatus = 'diagnostic_non_publishable'
  }
}

function Invoke-BlindJudge {
  if (-not $Apply) { Throw-RunnerError 'JUDGE_APPLY_REQUIRED' 'Judge calls require explicit -Apply.' }
  $inputPath = [IO.Path]::GetFullPath($JudgeInputPath)
  if ([string]::IsNullOrWhiteSpace($JudgeResultPath)) { Throw-RunnerError 'JUDGE_RESULT_OUTPUT_INVALID' 'Judge result path is required.' }
  $resultOutput = [IO.Path]::GetFullPath($JudgeResultPath)
  $resultParent = Split-Path -Parent $resultOutput
  if (-not (Test-Path -LiteralPath $resultParent)) { New-Item -ItemType Directory -Force -Path $resultParent | Out-Null }
  $judgeInput = Read-RunnerJson $inputPath 'JUDGE_INPUT_INVALID'
  if ([string]$judgeInput.schema -ne 'super-brain.objective-blind-judge-input.v1') { Throw-RunnerError 'JUDGE_INPUT_SCHEMA_INVALID' 'Judge input schema is unsupported.' }
  $inputHash = Get-ArtifactSha256 $inputPath 'JUDGE_INPUT_HASH_FAILED'
  $pairContractSha256 = Get-RequiredText $judgeInput 'pairContractSha256' 'JUDGE_INPUT_INVALID'
  if ($pairContractSha256 -notmatch '^[a-fA-F0-9]{64}$') { Throw-RunnerError 'JUDGE_INPUT_INVALID' 'Judge input pair contract hash is invalid.' }
  $pairContractSha256 = $pairContractSha256.ToLowerInvariant()
  $expectedJudgeModel = Get-RequiredText $judgeInput.judge 'modelId' 'JUDGE_INPUT_INVALID'
  $expectedJudgeReasoningEffort = Get-RequiredText $judgeInput.judge 'reasoningEffort' 'JUDGE_INPUT_INVALID'
  [void](Get-RequiredBoolean $judgeInput.judge 'independentExecution' 'JUDGE_INPUT_INVALID')
  $inputCases = @{}
  foreach ($case in @($judgeInput.cases)) {
    $id = Get-RequiredText $case 'id' 'JUDGE_INPUT_INVALID'
    if ($inputCases.ContainsKey($id)) { Throw-RunnerError 'JUDGE_INPUT_INVALID' "Duplicate judge input id: $id" }
    $inputCases[$id] = $case
  }
  $decisions = @{}
  $judgeRunId = 'judge-run-' + [guid]::NewGuid().ToString('N')
  $storedEndpointHash = ''
  $resumedCount = 0
  $transportProbeReceiptSha256 = ''
  if (Test-Path -LiteralPath $resultOutput) {
    $existing = Read-RunnerJson $resultOutput 'JUDGE_CHECKPOINT_INVALID'
    if ([string]$existing.schema -ne 'super-brain.objective-blind-judge-result.v1' -or [string]$existing.status -notin @('partial','completed')) {
      Throw-RunnerError 'JUDGE_CHECKPOINT_INVALID' 'Existing judge result is not a resumable checkpoint.'
    }
    if ([string]$existing.judgeInputSha256 -ne $inputHash) { Throw-RunnerError 'JUDGE_CHECKPOINT_INPUT_MISMATCH' 'Judge checkpoint belongs to a different blinded input.' }
    $existingPairContractSha256 = (Get-RequiredText $existing 'pairContractSha256' 'JUDGE_CHECKPOINT_INVALID').ToLowerInvariant()
    if ($existingPairContractSha256 -ne $pairContractSha256) { Throw-RunnerError 'JUDGE_CHECKPOINT_PAIR_CONTRACT_MISMATCH' 'Judge checkpoint belongs to another pair contract.' }
    $identityMatches = (
      [string]$existing.judge.modelId -eq $expectedJudgeModel -and
      [string]$existing.judge.reportedModelId -eq $expectedJudgeModel -and
      [string]$existing.judge.reasoningEffort -eq $expectedJudgeReasoningEffort -and
      (Get-RequiredBoolean $existing.judge 'modelIdentityVerified' 'JUDGE_CHECKPOINT_INVALID') -and
      (Get-RequiredBoolean $existing.judge 'independentExecution' 'JUDGE_CHECKPOINT_INVALID')
    )
    $legacyIdentityFieldsPresent = (
      $null -ne $existing.judge.PSObject.Properties['modelId'] -and
      $null -ne $existing.judge.PSObject.Properties['reportedModelId'] -and
      $null -ne $existing.judge.PSObject.Properties['reasoningEffort']
    )
    $legacyEmptyIdentity = (
      [string]$existing.status -in @('partial','completed') -and
      $legacyIdentityFieldsPresent -and
      [string]$existing.judge.modelId -eq '' -and
      [string]$existing.judge.reportedModelId -eq '' -and
      [string]$existing.judge.reasoningEffort -eq '' -and
      (Get-RequiredBoolean $existing.judge 'modelIdentityVerified' 'JUDGE_CHECKPOINT_INVALID') -and
      (Get-RequiredBoolean $existing.judge 'independentExecution' 'JUDGE_CHECKPOINT_INVALID')
    )
    if (-not $identityMatches -and -not $legacyEmptyIdentity) {
      Throw-RunnerError 'JUDGE_CHECKPOINT_IDENTITY_MISMATCH' 'Judge checkpoint identity differs from the prepared blind run.'
    }
    $judgeRunId = Get-RequiredText $existing.judge 'judgeRunId' 'JUDGE_CHECKPOINT_INVALID'
    $storedEndpointHash = Get-RequiredText $existing.judge 'endpointSha256' 'JUDGE_CHECKPOINT_ENDPOINT_MISSING'
    if ($null -ne $existing.judge.PSObject.Properties['transportProbeReceiptSha256']) {
      $transportProbeReceiptSha256 = [string]$existing.judge.transportProbeReceiptSha256
    }
    foreach ($decision in @($existing.decisions)) {
      $id = Get-RequiredText $decision 'id' 'JUDGE_CHECKPOINT_INVALID'
      if ($decisions.ContainsKey($id) -or -not $inputCases.ContainsKey($id)) { Throw-RunnerError 'JUDGE_CHECKPOINT_DECISIONS_INVALID' "Unexpected or duplicate checkpoint decision id: $id" }
      foreach ($name in @($decision.PSObject.Properties.Name)) {
        if ($name -match '(?i)baseline|treatment|condition') { Throw-RunnerError 'JUDGE_BLINDING_BROKEN' 'Judge checkpoint contains an unblinded condition field.' }
      }
      [void](Get-RequiredBoolean $decision.candidateA 'passed' 'JUDGE_CHECKPOINT_INVALID')
      [void](Get-RequiredBoolean $decision.candidateB 'passed' 'JUDGE_CHECKPOINT_INVALID')
      [void](Get-RequiredText $decision 'responseSha256' 'JUDGE_CHECKPOINT_INVALID')
      $responseModel = Get-RequiredText $decision 'responseModel' 'JUDGE_CHECKPOINT_INVALID'
      if ($responseModel -ne $expectedJudgeModel) { Throw-RunnerError 'JUDGE_REPORTED_MODEL_MISMATCH' "Checkpoint decision $id has an unexpected actual model." }
      $decisions[$id] = $decision
    }
    if ((Get-RequiredInteger $existing.judge 'responseCount' 'JUDGE_CHECKPOINT_INVALID') -ne $decisions.Count -or [string]$existing.judge.responseModelEvidenceSha256 -ne (Get-JudgeModelEvidenceHash $decisions)) {
      Throw-RunnerError 'JUDGE_CHECKPOINT_EVIDENCE_MISMATCH' 'Judge checkpoint count or model-evidence hash is invalid.'
    }
    $resumedCount = $decisions.Count
    if ($legacyEmptyIdentity) {
      $existing.judge.modelId = $expectedJudgeModel
      $existing.judge.reportedModelId = $expectedJudgeModel
      $existing.judge.reasoningEffort = $expectedJudgeReasoningEffort
      Write-RunnerJson $resultOutput $existing
    }
    if ([string]$existing.status -eq 'completed') {
      if ($decisions.Count -ne $inputCases.Count) { Throw-RunnerError 'JUDGE_CHECKPOINT_DECISIONS_INVALID' 'Completed judge checkpoint does not cover every case.' }
      return [pscustomobject]@{
        ok=$true; action='Judge'; schema='super-brain.objective-blind-judge-result.v1'; status='judged'
        judgeResultPath=$resultOutput; judgeResultSha256=(Get-ArtifactSha256 $resultOutput 'JUDGE_RESULT_HASH_FAILED')
        caseCount=$decisions.Count; resumedCount=$resumedCount; newDecisionCount=0
        pairContractSha256=$pairContractSha256
        judgeModel=$expectedJudgeModel; judgeReasoningEffort=$expectedJudgeReasoningEffort; rawJudgeResponseStored=$false
        transportProbeReceiptSha256=$transportProbeReceiptSha256
      }
    }
  }
  $connection = Get-JudgeConnection
  $uri = $connection.uri
  $apiKey = $connection.apiKey
  $endpointHash = Get-TextSha256 $uri.GetLeftPart([UriPartial]::Authority)
  if (-not [string]::IsNullOrWhiteSpace($storedEndpointHash) -and $storedEndpointHash -ne $endpointHash) {
    Throw-RunnerError 'JUDGE_CHECKPOINT_ENDPOINT_MISMATCH' 'Judge checkpoint belongs to a different endpoint authority.'
  }
  $pendingCaseIds = @($inputCases.Keys | Where-Object { -not $decisions.ContainsKey($_) })
  if ($pendingCaseIds.Count -gt 0) {
    $transportProbe = Assert-SuperBrainResponsesTransportProbeReceipt -Scope 'objective-judge' -Uri $uri -Model $expectedJudgeModel -ReasoningEffort $expectedJudgeReasoningEffort
    $transportProbeReceiptSha256 = [string]$transportProbe.receiptSha256
  }
  $writeProgress = {
    param([string]$Status)
    $orderedDecisions = @($decisions.Keys | Sort-Object | ForEach-Object { $decisions[$_] })
    Write-RunnerJson $resultOutput ([pscustomobject]@{
      schema = 'super-brain.objective-blind-judge-result.v1'
      status = $Status
      createdAt = (Get-Date).ToString('o')
      judgeInputSha256 = $inputHash
      pairContractSha256 = $pairContractSha256
      judge = [pscustomobject]@{
        modelId = $expectedJudgeModel
        reportedModelId = $expectedJudgeModel
        modelIdentityVerified = $true
        reasoningEffort = $expectedJudgeReasoningEffort
        judgeRunId = $judgeRunId
        independentExecution = $true
        endpointSha256 = $endpointHash
        transportProbeReceiptSha256 = $transportProbeReceiptSha256
        responseCount = $orderedDecisions.Count
        responseModelEvidenceSha256 = Get-JudgeModelEvidenceHash $decisions
      }
      decisions = $orderedDecisions
      rawJudgeResponseStored = $false
    })
  }
  & $writeProgress 'partial'
  foreach ($id in @($inputCases.Keys | Sort-Object)) {
    if ($decisions.ContainsKey($id)) { continue }
    $case = $inputCases[$id]
    $prompt = Get-RequiredText $case 'prompt' 'JUDGE_INPUT_INVALID'
    $candidateA = Get-RequiredText $case 'candidateA' 'JUDGE_INPUT_INVALID'
    $candidateB = Get-RequiredText $case 'candidateB' 'JUDGE_INPUT_INVALID'
    $reference = Get-OptionalText $case 'reference'
    $rubric = Get-OptionalText $case 'rubric'
    $request = @"
You are an independent blinded evaluator. Evaluate each candidate only against the task, reference, and rubric. Do not infer hidden system conditions. Return exactly one JSON object with this shape: {"candidateA":{"passed":true},"candidateB":{"passed":false}}.

Task:
$prompt

Reference:
$reference

Rubric:
$rubric

Candidate A:
$candidateA

Candidate B:
$candidateB
"@
    $response = Invoke-JudgeRequest $uri $apiKey $expectedJudgeModel $expectedJudgeReasoningEffort $request $TimeoutSeconds
    $decision = Get-JudgeDecisionFromText (Get-JudgeResponseText $response)
    $decisions[$id] = [pscustomobject]@{ id=$id; candidateA=$decision.candidateA; candidateB=$decision.candidateB; responseSha256=$decision.responseSha256; responseModel=(Get-JudgeResponseModel $response) }
    & $writeProgress 'partial'
  }
  & $writeProgress 'completed'
  return [pscustomobject]@{
    ok = $true
    action = 'Judge'
    schema = 'super-brain.objective-blind-judge-result.v1'
    status = 'judged'
    judgeResultPath = $resultOutput
    judgeResultSha256 = Get-ArtifactSha256 $resultOutput 'JUDGE_RESULT_HASH_FAILED'
    caseCount = $decisions.Count
    pairContractSha256 = $pairContractSha256
    resumedCount = $resumedCount
    newDecisionCount = $decisions.Count - $resumedCount
    judgeModel = $expectedJudgeModel
    judgeReasoningEffort = $expectedJudgeReasoningEffort
    transportProbeReceiptSha256 = $transportProbeReceiptSha256
    rawJudgeResponseStored = $false
  }
}

function Finalize-BlindRun {
  $stateFullPath = [IO.Path]::GetFullPath($StatePath)
  if ([string]::IsNullOrWhiteSpace($ExpectedStateSha256)) { Throw-RunnerError 'STATE_HASH_REQUIRED' 'Finalize requires the prepared state SHA-256 receipt.' }
  $preparedStateActualHash = Get-ArtifactSha256 $stateFullPath 'STATE_INVALID'
  if ($preparedStateActualHash -ne $ExpectedStateSha256.ToLowerInvariant()) {
    Throw-RunnerError 'STATE_TAMPERED' 'Prepared blind state no longer matches its receipt.'
  }
  $state = Read-RunnerJson $stateFullPath 'STATE_INVALID'
  if ([string]$state.schema -ne 'super-brain.objective-blind-run-state.v1') { Throw-RunnerError 'STATE_SCHEMA_INVALID' 'Blind run state schema is unsupported.' }
  if ([string]$state.status -ne 'awaiting_judge') { Throw-RunnerError 'STATE_NOT_AWAITING_JUDGE' 'Blind run is not awaiting a judge result.' }
  $statePairContractSha256 = (Get-RequiredText $state 'pairContractSha256' 'STATE_INVALID').ToLowerInvariant()
  if ($statePairContractSha256 -notmatch '^[a-f0-9]{64}$') { Throw-RunnerError 'STATE_INVALID' 'Prepared state pair contract hash is invalid.' }
  $judgeResultFullPath = [IO.Path]::GetFullPath($JudgeResultPath)
  $judgeResult = Read-RunnerJson $judgeResultFullPath 'JUDGE_RESULT_INVALID'
  if ([string]$judgeResult.schema -ne 'super-brain.objective-blind-judge-result.v1') { Throw-RunnerError 'JUDGE_RESULT_SCHEMA_INVALID' 'Judge result schema is unsupported.' }
  if ([string]$judgeResult.status -ne 'completed') { Throw-RunnerError 'JUDGE_RESULT_INCOMPLETE' 'Judge result is still partial and cannot be finalized.' }
  $judgeInputPath = [string]$state.judgeInput.path
  $judgeInputActualHash = Get-ArtifactSha256 $judgeInputPath 'JUDGE_INPUT_TAMPERED'
  if ($judgeInputActualHash -ne [string]$state.judgeInput.sha256 -or $judgeInputActualHash -ne [string]$judgeResult.judgeInputSha256) {
    Throw-RunnerError 'JUDGE_INPUT_TAMPERED' 'Judge input no longer matches the prepared blind artifact.'
  }
  $judgeInput = Read-RunnerJson $judgeInputPath 'JUDGE_INPUT_INVALID'
  $judgeInputPairContractSha256 = (Get-RequiredText $judgeInput 'pairContractSha256' 'JUDGE_INPUT_INVALID').ToLowerInvariant()
  $judgeResultPairContractSha256 = (Get-RequiredText $judgeResult 'pairContractSha256' 'JUDGE_RESULT_INVALID').ToLowerInvariant()
  if ($judgeInputPairContractSha256 -ne $statePairContractSha256 -or $judgeResultPairContractSha256 -ne $statePairContractSha256) {
    Throw-RunnerError 'PAIR_CONTRACT_CHAIN_MISMATCH' 'Prepared state, blinded input, and judge result do not share one pair contract.'
  }
  if ([string]$judgeResult.judge.modelId -ne [string]$state.judge.modelId -or [string]$judgeResult.judge.reasoningEffort -ne [string]$state.judge.reasoningEffort) {
    Throw-RunnerError 'JUDGE_IDENTITY_MISMATCH' 'Judge model identity or reasoning effort differs from the prepared run.'
  }
  if ([string]$judgeResult.judge.reportedModelId -ne [string]$state.judge.modelId -or -not (Get-RequiredBoolean $judgeResult.judge 'modelIdentityVerified' 'JUDGE_RESULT_INVALID')) {
    Throw-RunnerError 'JUDGE_REPORTED_MODEL_MISMATCH' 'Judge result lacks verified actual-model identity for the prepared model.'
  }
  if (-not (Get-RequiredBoolean $judgeResult.judge 'independentExecution' 'JUDGE_RESULT_INVALID')) {
    Throw-RunnerError 'JUDGE_NOT_INDEPENDENT' 'Judge result does not declare an independent execution.'
  }
  $baselineArtifact = Get-AnswerArtifact ([string]$state.baselineArtifact.path) $false 'Baseline'
  $treatmentArtifact = Get-AnswerArtifact ([string]$state.treatmentArtifact.path) $true 'Treatment'
  Assert-ComparableAnswerArtifacts $baselineArtifact $treatmentArtifact
  if ([string]$baselineArtifact.pairContractSha256 -ne $statePairContractSha256 -or [string]$treatmentArtifact.pairContractSha256 -ne $statePairContractSha256) {
    Throw-RunnerError 'PAIR_CONTRACT_CHAIN_MISMATCH' 'Source answer artifacts do not match the prepared pair contract.'
  }
  if ([string]$baselineArtifact.sha256 -ne [string]$state.baselineArtifact.sha256 -or [string]$treatmentArtifact.sha256 -ne [string]$state.treatmentArtifact.sha256) {
    Throw-RunnerError 'ANSWER_ARTIFACT_TAMPERED' 'A source answer artifact changed after blind preparation.'
  }
  $output = Get-NewOutputPath $OutputPath 'REPORT_OUTPUT_INVALID'
  $pairings = @{}
  foreach ($pairing in @($state.pairings)) {
    $id = Get-RequiredText $pairing 'id' 'STATE_INVALID'
    if ($pairings.ContainsKey($id)) { Throw-RunnerError 'STATE_INVALID' "Duplicate pairing id: $id" }
    if (-not $baselineArtifact.cases.ContainsKey($id) -or -not $treatmentArtifact.cases.ContainsKey($id)) { Throw-RunnerError 'STATE_INVALID' "Pairing references an unknown case: $id" }
    $conditionA = Get-RequiredText $pairing 'candidateACondition' 'STATE_INVALID'
    $conditionB = Get-RequiredText $pairing 'candidateBCondition' 'STATE_INVALID'
    if ($conditionA -notin @('baseline','treatment') -or $conditionB -notin @('baseline','treatment') -or $conditionA -eq $conditionB) {
      Throw-RunnerError 'STATE_PAIRING_INVALID' "Pairing conditions are not complementary for case: $id"
    }
    if ([string]$pairing.baselineAnswerSha256 -ne [string]$baselineArtifact.cases[$id].answerSha256 -or [string]$pairing.treatmentAnswerSha256 -ne [string]$treatmentArtifact.cases[$id].answerSha256 -or [string]$pairing.caseShapeSha256 -ne [string]$baselineArtifact.cases[$id].shapeHash) {
      Throw-RunnerError 'STATE_PAIRING_INVALID' "Pairing evidence does not match the source artifacts for case: $id"
    }
    $pairings[$id] = $pairing
  }
  $decisions = @{}
  foreach ($decision in @($judgeResult.decisions)) {
    $id = Get-RequiredText $decision 'id' 'JUDGE_RESULT_INVALID'
    if ($decisions.ContainsKey($id) -or -not $pairings.ContainsKey($id)) { Throw-RunnerError 'JUDGE_DECISION_SET_INVALID' "Unexpected or duplicate judge decision id: $id" }
    foreach ($name in @($decision.PSObject.Properties.Name)) {
      if ($name -match '(?i)baseline|treatment|condition') { Throw-RunnerError 'JUDGE_BLINDING_BROKEN' 'Judge decision contains an unblinded condition field.' }
    }
    [void](Get-RequiredBoolean $decision.candidateA 'passed' 'JUDGE_RESULT_INVALID')
    [void](Get-RequiredBoolean $decision.candidateB 'passed' 'JUDGE_RESULT_INVALID')
    [void](Get-RequiredText $decision 'responseSha256' 'JUDGE_RESULT_INVALID')
    $responseModel = Get-RequiredText $decision 'responseModel' 'JUDGE_RESULT_INVALID'
    if ($responseModel -ne [string]$judgeResult.judge.reportedModelId) { Throw-RunnerError 'JUDGE_REPORTED_MODEL_MISMATCH' "Judge decision $id has an unexpected actual model." }
    $decisions[$id] = $decision
  }
  if ($decisions.Count -ne $pairings.Count) { Throw-RunnerError 'JUDGE_DECISION_SET_INVALID' 'Judge result does not cover every prepared case exactly once.' }
  if ((Get-RequiredInteger $judgeResult.judge 'responseCount' 'JUDGE_RESULT_INVALID') -ne $decisions.Count -or [string]$judgeResult.judge.responseModelEvidenceSha256 -ne (Get-JudgeModelEvidenceHash $decisions)) {
    Throw-RunnerError 'JUDGE_MODEL_EVIDENCE_MISMATCH' 'Judge response count or model-evidence hash is invalid.'
  }

  $cases = New-Object Collections.ArrayList
  $baselinePassed = 0
  $treatmentPassed = 0
  $wins = 0
  $losses = 0
  foreach ($id in @($pairings.Keys | Sort-Object)) {
    $pairing = $pairings[$id]
    $decision = $decisions[$id]
    $aPassed = [bool]$decision.candidateA.passed
    $bPassed = [bool]$decision.candidateB.passed
    $basePassed = if ([string]$pairing.candidateACondition -eq 'baseline') { $aPassed } else { $bPassed }
    $treatPassed = if ([string]$pairing.candidateACondition -eq 'treatment') { $aPassed } else { $bPassed }
    if ($basePassed) { $baselinePassed++ }
    if ($treatPassed) { $treatmentPassed++ }
    if (-not $basePassed -and $treatPassed) { $wins++ }
    if ($basePassed -and -not $treatPassed) { $losses++ }
    $winner = if ($aPassed -eq $bPassed) { 'tie' } elseif ($aPassed) { 'A' } else { 'B' }
    [void]$cases.Add([pscustomobject]@{
      id = $id
      baselinePassed = $basePassed
      treatmentPassed = $treatPassed
      blindedWinner = $winner
      judgeDecisionSha256 = Get-TextSha256 ($decision | ConvertTo-Json -Depth 12 -Compress)
      baselineAnswerSha256 = [string]$pairing.baselineAnswerSha256
      treatmentAnswerSha256 = [string]$pairing.treatmentAnswerSha256
    })
  }

  $state.status = 'finalized'
  $state.finalizedAt = (Get-Date).ToString('o')
  $state.judgeResult = [pscustomobject]@{ path=$judgeResultFullPath; sha256=(Get-ArtifactSha256 $judgeResultFullPath 'JUDGE_RESULT_HASH_FAILED') }
  $state.rawJudgeResponseStored = $false
  Write-RunnerJson $stateFullPath $state
  $total = $cases.Count
  $report = [pscustomobject]@{
    ok = $true
    action = 'Finalize'
    schema = 'super-brain.objective-blind-judge-report.v1'
    status = 'diagnostic_non_publishable'
    publicationGuard = 'This blinded diagnostic is not an official benchmark result. Normalize only a separately proven official-harness run through objective-benchmark.ps1.'
    packageVersion = [string](Get-SuperBrainManifest $Root).version
    benchmarkVariant = [string]$state.benchmarkVariant
    caseSetHash = [string]$state.caseSetHash
    pairContractSha256 = $statePairContractSha256
    metrics = [pscustomobject]@{
      total = $total
      baselinePassed = $baselinePassed
      treatmentPassed = $treatmentPassed
      baselinePassRate = [Math]::Round($baselinePassed / [double]$total,6)
      treatmentPassRate = [Math]::Round($treatmentPassed / [double]$total,6)
      pairedDeltaPercentagePoints = [Math]::Round((($treatmentPassed-$baselinePassed) / [double]$total) * 100.0,4)
      treatmentWins = $wins
      treatmentLosses = $losses
      ties = $total - $wins - $losses
    }
    judge = [pscustomobject]@{ modelId=[string]$state.judge.modelId; reportedModelId=[string]$judgeResult.judge.reportedModelId; modelIdentityVerified=$true; reasoningEffort=[string]$state.judge.reasoningEffort; independentExecution=$true }
    provenance = [pscustomobject]@{
      state = [pscustomobject]@{ path=$stateFullPath; sha256=(Get-ArtifactSha256 $stateFullPath 'STATE_HASH_FAILED') }
      preparedStateSha256 = $preparedStateActualHash
      baselineArtifact = [pscustomobject]@{ path=[string]$state.baselineArtifact.path; sha256=[string]$state.baselineArtifact.sha256 }
      treatmentArtifact = [pscustomobject]@{ path=[string]$state.treatmentArtifact.path; sha256=[string]$state.treatmentArtifact.sha256 }
      judgeInput = [pscustomobject]@{ path=$judgeInputPath; sha256=$judgeInputActualHash }
      pairContractSha256 = $statePairContractSha256
      judgeResult = $state.judgeResult
      randomizedOrder = $true
      blindedJudging = $true
      independentGeneratorRuns = $true
      rawAnswersStored = $false
      rawJudgeResponseStored = $false
    }
    cases = @($cases)
    reportPath = $output
  }
  Write-RunnerJson $output $report
  return $report
}

function Invoke-JudgeProbe {
  if (-not $Apply) { Throw-RunnerError 'PROBE_APPLY_REQUIRED' 'Judge probing requires explicit -Apply.' }
  $connection = Get-JudgeConnection
  $uri = $connection.uri
  $apiKey = $connection.apiKey
  try {
    $probe = Invoke-SuperBrainResponsesProbe -Uri $uri -ApiKey $apiKey -Model $JudgeModel -ReasoningEffort $JudgeReasoningEffort -RequestInput 'Reply exactly with OK.' -MaxOutputTokens 256 -TimeoutSeconds $TimeoutSeconds -MaxAttempts $JudgeProbeMaxAttempts -RetryDelayMilliseconds $JudgeProbeRetryDelayMilliseconds
    $response = $probe.result.response
  } catch {
    $parts = $_.Exception.Message -split '\|',2
    $code = if ($parts.Count -eq 2) { [string]$parts[0] } else { '' }
    if ($code -eq 'RESPONSES_REPORTED_MODEL_MISMATCH') { Throw-RunnerError 'JUDGE_REPORTED_MODEL_MISMATCH' "Judge requested $JudgeModel but the endpoint reported another model." }
    if ($code -eq 'RESPONSES_REPORTED_MODEL_MISSING') { Throw-RunnerError 'JUDGE_REPORTED_MODEL_MISSING' 'Judge response does not report its actual model identity.' }
    $detail = if ([string]::IsNullOrWhiteSpace($code)) { 'unclassified' } else { $code }
    Throw-RunnerError 'JUDGE_API_FAILED' "Judge Responses probe failed through the verified transport client: $detail."
  }
  $reportedModel = Get-JudgeResponseModel $response
  $receipt = Write-SuperBrainResponsesTransportProbeReceipt -Scope 'objective-judge' -Uri $uri -Model $JudgeModel -ReasoningEffort $JudgeReasoningEffort
  return [pscustomobject]@{
    ok = $true
    action = 'Probe'
    schema = 'super-brain.objective-judge-probe.v1'
    status = 'reachable'
    judgeModel = $JudgeModel
    reportedModelId = $reportedModel
    modelIdentityVerified = $true
    judgeReasoningEffort = $JudgeReasoningEffort
    transportProbeReceiptSha256 = $receipt.sha256
    probeAttemptCount = [int]$probe.attemptCount
    transportRetryCount = [int]$probe.retryCount
    responseSha256 = Get-TextSha256 (($response | ConvertTo-Json -Depth 20 -Compress))
    credentialStored = $false
  }
}

function Get-RunnerStatus {
  $connection = Resolve-SuperBrainResponsesConnection -ExplicitResponsesUrl $JudgeResponsesUrl -PrimaryResponsesUrlEnvironment 'SUPER_BRAIN_JUDGE_RESPONSES_URL' -ApiKeyEnvironment $JudgeApiKeyEnv
  $urlConfigured = -not [string]::IsNullOrWhiteSpace([string]$connection.responsesUrl)
  $keyConfigured = -not [string]::IsNullOrWhiteSpace([string]$connection.apiKey)
  return [pscustomobject]@{
    ok = $true
    action = 'Status'
    schema = 'super-brain.objective-blind-runner-status.v1'
    status = if($urlConfigured -and $keyConfigured){'configured_unverified'}else{'configuration_required'}
    judgeModel = $JudgeModel
    judgeReasoningEffort = $JudgeReasoningEffort
    judgeResponsesUrlConfigured = $urlConfigured
    judgeApiKeyConfigured = $keyConfigured
    endpointSource = [string]$connection.endpointSource
    credentialSource = [string]$connection.credentialSource
    configuredEndpointStored = $false
    credentialStored = $false
    nextAction = if($urlConfigured -and $keyConfigured){'Run Probe with -Apply before a full blind judge run.'}else{'Provide a non-secret judge URL and set the configured API key environment variable outside package files.'}
  }
}

function Write-Result($Value,[int]$ExitCode=0) {
  if ($Json) { $Value | ConvertTo-Json -Depth 30 }
  elseif ($Value.ok -eq $true) { Write-Host "OBJECTIVE_BLIND_RUNNER action=$Action status=$($Value.status)" }
  else { Write-Host "OBJECTIVE_BLIND_RUNNER_FAILED code=$($Value.code)" }
  exit $ExitCode
}

try {
  $result = switch ($Action) {
    'Status' { Get-RunnerStatus }
    'Prepare' { New-PreparedRun }
    'Judge' { Invoke-BlindJudge }
    'ExportNative' { Export-NativeJudgeBatches }
    'ImportNative' { Import-NativeJudgeBatches }
    'Finalize' { Finalize-BlindRun }
    'Probe' { Invoke-JudgeProbe }
  }
  Write-Result $result 0
} catch {
  $parts = $_.Exception.Message -split '\|',2
  $code = if($parts.Count -eq 2){$parts[0]}else{'OBJECTIVE_BLIND_RUNNER_ERROR'}
  $message = if($parts.Count -eq 2){$parts[1]}else{$_.Exception.Message}
  Write-Result ([pscustomobject]@{ ok=$false; action=$Action; schema='super-brain.objective-blind-runner-error.v1'; code=$code; error=$message; credentialStored=$false }) 1
}
