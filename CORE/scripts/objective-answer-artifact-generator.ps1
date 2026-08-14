[CmdletBinding(PositionalBinding = $false)]
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
  [ValidateRange(64,8192)]
  [int]$MaxOutputTokens = 512,
  [ValidateRange(5,300)]
  [int]$TimeoutSeconds = 180,
  [ValidateRange(1,3)]
  [int]$ProbeMaxAttempts = 3,
  [ValidateRange(0,10000)]
  [int]$ProbeRetryDelayMilliseconds = 750,
  [ValidateRange(1,1)]
  [int]$MaxBatchAttempts = 1,
  [ValidateRange(1,20)]
  [int]$BatchSize = 10,
  [string]$CheckpointPath = '',
  [ValidateRange(0,5000)]
  [int]$MaxNewBatches = 0,
  [string]$NativeManifestPath = '',
  [string]$NativeResponseDirectory = '',
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

function Throw-ObjectiveGeneratorError([string]$Code, [string]$Message) {
  throw [InvalidOperationException]::new("$Code|$Message")
}

function Read-ObjectiveGeneratorJson([string]$Path, [string]$Code) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Throw-ObjectiveGeneratorError $Code 'Required private answer-input artifact is missing.'
  }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Throw-ObjectiveGeneratorError $Code 'Required private answer-input artifact is invalid.' }
}

function Get-ObjectiveRequiredText($Object, [string]$Name, [string]$Code, [int]$Maximum = 12000) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { Throw-ObjectiveGeneratorError $Code "Missing field: $Name" }
  $value = [string]$Object.PSObject.Properties[$Name].Value
  if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt $Maximum) { Throw-ObjectiveGeneratorError $Code "Invalid field: $Name" }
  return $value
}

function Get-ObjectiveOptionalText($Object, [string]$Name, [int]$Maximum = 12000) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return '' }
  $value = [string]$Object.PSObject.Properties[$Name].Value
  if ($value.Length -gt $Maximum) { Throw-ObjectiveGeneratorError 'OBJECTIVE_INPUT_FIELD_INVALID' "Field is too large: $Name" }
  return $value
}

function Get-ObjectiveRequiredBoolean($Object, [string]$Name, [string]$Code) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name] -or $Object.PSObject.Properties[$Name].Value -isnot [bool]) {
    Throw-ObjectiveGeneratorError $Code "Boolean field required: $Name"
  }
  return [bool]$Object.PSObject.Properties[$Name].Value
}

function Get-ObjectiveRequiredInteger($Object, [string]$Name, [string]$Code) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { Throw-ObjectiveGeneratorError $Code "Missing integer field: $Name" }
  $value = $Object.PSObject.Properties[$Name].Value
  if ($value -isnot [byte] -and $value -isnot [int16] -and $value -isnot [int32] -and $value -isnot [int64]) {
    Throw-ObjectiveGeneratorError $Code "Integer field required: $Name"
  }
  return [int64]$value
}

function Get-ObjectiveSha256([string]$Value, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[a-fA-F0-9]{64}$') {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_INPUT_HASH_INVALID' "Invalid SHA-256 field: $Name"
  }
  return $Value.ToLowerInvariant()
}

function Get-ObjectiveFileSha256([string]$Path, [string]$Code) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Throw-ObjectiveGeneratorError $Code 'Required package file is missing.' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ObjectivePairContract($AnswerInput, $Benchmark) {
  if ($null -eq $AnswerInput.PSObject.Properties['pairContract'] -or $null -eq $AnswerInput.pairContract) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_REQUIRED' 'A shared immutable pair contract is required.'
  }
  $reference = $AnswerInput.pairContract
  $path = Get-ObjectiveRequiredText $reference 'path' 'OBJECTIVE_PAIR_CONTRACT_INVALID' 4096
  $expectedHash = Get-ObjectiveSha256 (Get-ObjectiveRequiredText $reference 'sha256' 'OBJECTIVE_PAIR_CONTRACT_INVALID' 64) 'pairContract.sha256'
  $fullPath = [IO.Path]::GetFullPath($path)
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $privateRoot = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($privateRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_NOT_PRIVATE' 'A package-local pair contract must live under private-state.'
  }
  $actualHash = Get-ObjectiveFileSha256 $fullPath 'OBJECTIVE_PAIR_CONTRACT_MISSING'
  if ($actualHash -ne $expectedHash) { Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_TAMPERED' 'Pair contract no longer matches its input receipt.' }
  $contract = Read-ObjectiveGeneratorJson $fullPath 'OBJECTIVE_PAIR_CONTRACT_INVALID'
  if ([string]$contract.schema -ne 'super-brain.objective-pair-contract.v1') {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_INVALID' 'Pair contract schema is unsupported.'
  }
  if ($null -eq $contract.PSObject.Properties['benchmark'] -or $null -eq $contract.PSObject.Properties['selection'] -or $null -eq $contract.PSObject.Properties['generationBudget']) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_INVALID' 'Pair contract is missing benchmark, selection, or generation budget.'
  }
  $contractBenchmark = $contract.benchmark
  foreach ($field in @('id','variant','corpusSha256','harnessSha256')) {
    if ([string](Get-ObjectiveRequiredText $contractBenchmark $field 'OBJECTIVE_PAIR_CONTRACT_INVALID' 160) -ne [string]$Benchmark.PSObject.Properties[$field].Value) {
      Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_MISMATCH' "Pair contract benchmark differs for $field."
    }
  }
  $contractSelection = $contract.selection
  $contractSelectionHash = Get-ObjectiveSha256 (Get-ObjectiveRequiredText $contractSelection 'selectionSha256' 'OBJECTIVE_PAIR_CONTRACT_INVALID' 64) 'pairContract.selection.selectionSha256'
  if ($contractSelectionHash -ne [string]$Benchmark.selectionSha256) { Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_MISMATCH' 'Pair contract selection hash differs from answer input.' }
  $contractCaseSetHash = Get-ObjectiveSha256 (Get-ObjectiveRequiredText $contractSelection 'caseSetHash' 'OBJECTIVE_PAIR_CONTRACT_INVALID' 64) 'pairContract.selection.caseSetHash'
  $contractCaseCount = Get-ObjectiveRequiredInteger $contractSelection 'caseCount' 'OBJECTIVE_PAIR_CONTRACT_INVALID'
  if ($contractCaseCount -lt 1) { Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_INVALID' 'Pair contract case count must be positive.' }
  $budget = $contract.generationBudget
  $budgetModel = Get-ObjectiveRequiredText $budget 'modelId' 'OBJECTIVE_PAIR_CONTRACT_INVALID' 160
  $budgetEffort = Get-ObjectiveRequiredText $budget 'reasoningEffort' 'OBJECTIVE_PAIR_CONTRACT_INVALID' 32
  $budgetOutputTokens = Get-ObjectiveRequiredInteger $budget 'maxOutputTokens' 'OBJECTIVE_PAIR_CONTRACT_INVALID'
  $budgetTimeout = Get-ObjectiveRequiredInteger $budget 'timeoutSeconds' 'OBJECTIVE_PAIR_CONTRACT_INVALID'
  $budgetBatchSize = Get-ObjectiveRequiredInteger $budget 'batchSize' 'OBJECTIVE_PAIR_CONTRACT_INVALID'
  $budgetAttempts = Get-ObjectiveRequiredInteger $budget 'maxBatchAttempts' 'OBJECTIVE_PAIR_CONTRACT_INVALID'
  $budgetTopK = Get-ObjectiveRequiredInteger $budget 'retrievalTopK' 'OBJECTIVE_PAIR_CONTRACT_INVALID'
  $budgetRetrievalTokens = Get-ObjectiveRequiredInteger $budget 'retrievalMaxTokens' 'OBJECTIVE_PAIR_CONTRACT_INVALID'
  if ($budgetOutputTokens -lt 64 -or $budgetTimeout -lt 5 -or $budgetBatchSize -lt 1 -or $budgetAttempts -ne 1 -or $budgetTopK -lt 1 -or $budgetRetrievalTokens -lt 32) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_INVALID' 'Pair contract contains an invalid generation or retrieval budget.'
  }
  if ([string](Get-ObjectiveRequiredText $contract 'singleChangedVariable' 'OBJECTIVE_PAIR_CONTRACT_INVALID' 80) -ne 'super_memory_brain_enabled') {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_INVALID' 'Pair contract must declare super_memory_brain_enabled as its only changed variable.'
  }
  if ($null -eq $contract.PSObject.Properties['baseline'] -or $null -eq $contract.PSObject.Properties['treatment'] -or
      (Get-ObjectiveRequiredBoolean $contract.baseline 'superMemoryBrainEnabled' 'OBJECTIVE_PAIR_CONTRACT_INVALID') -or
      -not (Get-ObjectiveRequiredBoolean $contract.treatment 'superMemoryBrainEnabled' 'OBJECTIVE_PAIR_CONTRACT_INVALID')) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_INVALID' 'Pair contract baseline/treatment conditions are invalid.'
  }
  return [pscustomobject]@{
    path=$fullPath
    sha256=$actualHash
    caseSetHash=$contractCaseSetHash
    caseCount=$contractCaseCount
    generationBudget=[pscustomobject]@{
      modelId=$budgetModel
      reasoningEffort=$budgetEffort
      maxOutputTokens=$budgetOutputTokens
      timeoutSeconds=$budgetTimeout
      batchSize=$budgetBatchSize
      maxBatchAttempts=$budgetAttempts
      retrievalTopK=$budgetTopK
      retrievalMaxTokens=$budgetRetrievalTokens
    }
  }
}

function Assert-ObjectiveGenerationBudget($PairContract) {
  $budget = $PairContract.generationBudget
  if ([string]$budget.modelId -ne $Model -or [string]$budget.reasoningEffort -ne $ReasoningEffort -or
      [int]$budget.maxOutputTokens -ne $MaxOutputTokens -or [int]$budget.timeoutSeconds -ne $TimeoutSeconds -or
      [int]$budget.batchSize -ne $BatchSize -or [int]$budget.maxBatchAttempts -ne $MaxBatchAttempts) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_BUDGET_MISMATCH' 'Command generation budget does not match the shared pair contract.'
  }
}

function Get-ObjectiveCaseShapeHash($Case) {
  $id = Get-ObjectiveRequiredText $Case 'id' 'OBJECTIVE_INPUT_CASE_INVALID' 160
  $prompt = Get-ObjectiveRequiredText $Case 'prompt' 'OBJECTIVE_INPUT_CASE_INVALID' 12000
  $reference = Get-ObjectiveRequiredText $Case 'reference' 'OBJECTIVE_INPUT_CASE_INVALID' 12000
  $rubric = Get-ObjectiveRequiredText $Case 'rubric' 'OBJECTIVE_INPUT_CASE_INVALID' 12000
  return (Get-SuperBrainTextSha256 ($id + "`n" + $prompt + "`n" + $reference + "`n" + $rubric))
}

function Get-ObjectiveCaseSetHash($Cases) {
  $parts = @($Cases.Keys | Sort-Object | ForEach-Object {
    $case = $Cases[$_]
    ([string]$case.id) + "`n" + ([string]$case.shapeHash)
  })
  return Get-SuperBrainTextSha256 ($parts -join "`n")
}

function Get-ObjectiveResponseModelEvidenceHash($Cases) {
  $parts = @($Cases | Sort-Object id | ForEach-Object { ([string]$_.id) + "`n" + ([string]$_.responseModel) })
  return Get-SuperBrainTextSha256 ($parts -join "`n")
}

function Get-ObjectivePrivateOutputPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_OUTPUT_REQUIRED' 'A private answer artifact output path is required.' }
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $fullPath) { Throw-ObjectiveGeneratorError 'OBJECTIVE_OUTPUT_EXISTS' 'Refusing to overwrite an existing answer artifact.' }
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $privateStatePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($privateStatePath, [StringComparison]::OrdinalIgnoreCase)) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_OUTPUT_NOT_PRIVATE' 'Answer artifacts inside the package must be written under private-state.'
  }
  $parent = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  return $fullPath
}

function Get-ObjectiveExistingPrivateArtifactPath([string]$Path, [string]$Code, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Throw-ObjectiveGeneratorError $Code "Required $Label artifact is missing."
  }
  $fullPath = [IO.Path]::GetFullPath($Path)
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $privateStatePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($privateStatePath, [StringComparison]::OrdinalIgnoreCase)) {
    Throw-ObjectiveGeneratorError $Code "$Label artifacts inside the package must be written under private-state."
  }
  return $fullPath
}

function Get-ObjectiveNewPrivateDirectoryPath([string]$Path, [string]$Code, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path)) { Throw-ObjectiveGeneratorError $Code "A private $Label directory is required." }
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $fullPath) { Throw-ObjectiveGeneratorError $Code "Refusing to reuse an existing $Label directory." }
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $privateStatePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($privateStatePath, [StringComparison]::OrdinalIgnoreCase)) {
    Throw-ObjectiveGeneratorError $Code "$Label directories inside the package must be written under private-state."
  }
  $parent = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  New-Item -ItemType Directory -Path $fullPath -ErrorAction Stop | Out-Null
  return $fullPath
}

function Get-ObjectiveExistingPrivateDirectoryPath([string]$Path, [string]$Code, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
    Throw-ObjectiveGeneratorError $Code "Required $Label directory is missing."
  }
  $fullPath = [IO.Path]::GetFullPath($Path)
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $privateStatePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($privateStatePath, [StringComparison]::OrdinalIgnoreCase)) {
    Throw-ObjectiveGeneratorError $Code "$Label directories inside the package must be under private-state."
  }
  return $fullPath
}

function Write-ObjectiveGeneratorJsonAtomic([string]$Path, $Value) {
  $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
  $backup = "$Path.$([guid]::NewGuid().ToString('N')).bak"
  try {
    [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporary, $Path, $backup) }
    else { [IO.File]::Move($temporary, $Path) }
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
  }
}

function Get-ObjectivePrivateCheckpointPath([string]$OutputPath, [string]$RequestedPath) {
  $candidate = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { $OutputPath + '.checkpoint.json' } else { $RequestedPath }
  $fullPath = [IO.Path]::GetFullPath($candidate)
  if ($fullPath -ieq [IO.Path]::GetFullPath($OutputPath)) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_OUTPUT_COLLISION' 'Checkpoint and answer artifact paths must be different.'
  }
  $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
  $privateStatePath = (Join-Path $Root 'private-state').TrimEnd('\') + '\'
  if ($fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($privateStatePath, [StringComparison]::OrdinalIgnoreCase)) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_NOT_PRIVATE' 'Checkpoints inside the package must be written under private-state.'
  }
  $parent = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  return $fullPath
}

function Get-ObjectiveGenerationMetadata($Preflight, $Connection, $TransportProbe) {
  $scriptHash = Get-ObjectiveFileSha256 $PSCommandPath 'OBJECTIVE_GENERATOR_HASH_FAILED'
  $manifestHash = Get-ObjectiveFileSha256 (Join-Path $Root 'manifest.json') 'OBJECTIVE_PACKAGE_HASH_FAILED'
  $brainCoreHash = Get-ObjectiveFileSha256 (Join-Path $Root 'runtime\brain_core.py') 'OBJECTIVE_PACKAGE_HASH_FAILED'
  $memoryPolicyHash = Get-ObjectiveFileSha256 (Join-Path $Root 'memory-policy.json') 'OBJECTIVE_PACKAGE_HASH_FAILED'
  $responsesClientHash = Get-ObjectiveFileSha256 (Join-Path $Root 'runtime\responses_api_client.py') 'OBJECTIVE_PACKAGE_HASH_FAILED'
  $endpointHash = Get-SuperBrainTextSha256 $Connection.uri.GetLeftPart([UriPartial]::Authority)
  $toolchainHash = Get-SuperBrainTextSha256 ($scriptHash + "`n" + $responsesClientHash)
  $budgetHash = Get-SuperBrainTextSha256 ($Model + "`n" + $ReasoningEffort + "`n" + $MaxOutputTokens + "`n" + $BatchSize + "`n" + $MaxBatchAttempts + "`n" + $TimeoutSeconds + "`n" + $Preflight.pairContract.generationBudget.retrievalTopK + "`n" + $Preflight.pairContract.generationBudget.retrievalMaxTokens)
  $environmentHash = Get-SuperBrainTextSha256 ($endpointHash + "`n" + [string]$PSVersionTable.PSVersion + "`n" + [Environment]::OSVersion.VersionString)
  $promptTemplateHash = Get-SuperBrainTextSha256 'objective-answer-template-v1:case-id,task-prompt,retrieved-context;references-and-rubrics-never-sent'
  $subjectHash = Get-SuperBrainTextSha256 ($manifestHash + "`n" + $brainCoreHash + "`n" + $memoryPolicyHash)
  $configFingerprint = Get-SuperBrainTextSha256 ((@(
    'longmemeval','s_cleaned',$Preflight.caseSetHash,$Preflight.benchmark.corpusSha256,$Preflight.benchmark.harnessSha256,$Preflight.benchmark.selectionSha256,$Preflight.pairContract.sha256,
    $Model,$toolchainHash,$budgetHash,$environmentHash,$promptTemplateHash,$subjectHash,$manifestHash,$brainCoreHash,$memoryPolicyHash
  ) -join "`n"))
  $manifest = Get-SuperBrainManifest $Root
  return [pscustomobject]@{
    scriptHash=$scriptHash
    manifest=$manifest
    manifestHash=$manifestHash
    brainCoreHash=$brainCoreHash
    memoryPolicyHash=$memoryPolicyHash
    responsesClientHash=$responsesClientHash
    endpointHash=$endpointHash
    toolchainHash=$toolchainHash
    budgetHash=$budgetHash
    environmentHash=$environmentHash
    promptTemplateHash=$promptTemplateHash
    subjectHash=$subjectHash
    configFingerprint=$configFingerprint
    transportProbeReceiptSha256=[string]$TransportProbe.receiptSha256
  }
}

function Get-ObjectiveNativeGenerationMetadata($Preflight) {
  $scriptHash = Get-ObjectiveFileSha256 $PSCommandPath 'OBJECTIVE_GENERATOR_HASH_FAILED'
  $manifestHash = Get-ObjectiveFileSha256 (Join-Path $Root 'manifest.json') 'OBJECTIVE_PACKAGE_HASH_FAILED'
  $brainCoreHash = Get-ObjectiveFileSha256 (Join-Path $Root 'runtime\brain_core.py') 'OBJECTIVE_PACKAGE_HASH_FAILED'
  $memoryPolicyHash = Get-ObjectiveFileSha256 (Join-Path $Root 'memory-policy.json') 'OBJECTIVE_PACKAGE_HASH_FAILED'
  $nativeHostHash = Get-SuperBrainTextSha256 'codex-desktop-native-agent-host-v1'
  $toolchainHash = Get-SuperBrainTextSha256 ($scriptHash + "`n" + $nativeHostHash)
  $budgetHash = Get-SuperBrainTextSha256 ($Model + "`n" + $ReasoningEffort + "`n" + $MaxOutputTokens + "`n" + $BatchSize + "`n" + $MaxBatchAttempts + "`n" + $TimeoutSeconds + "`n" + $Preflight.pairContract.generationBudget.retrievalTopK + "`n" + $Preflight.pairContract.generationBudget.retrievalMaxTokens)
  $environmentHash = Get-SuperBrainTextSha256 ($nativeHostHash + "`n" + [string]$PSVersionTable.PSVersion + "`n" + [Environment]::OSVersion.VersionString)
  $promptTemplateHash = Get-SuperBrainTextSha256 'objective-native-answer-batch-v1:case-id,task-prompt,retrieved-context;references-and-rubrics-never-sent'
  $subjectHash = Get-SuperBrainTextSha256 ($manifestHash + "`n" + $brainCoreHash + "`n" + $memoryPolicyHash)
  $configFingerprint = Get-SuperBrainTextSha256 ((@(
    'longmemeval','s_cleaned',$Preflight.caseSetHash,$Preflight.benchmark.corpusSha256,$Preflight.benchmark.harnessSha256,$Preflight.benchmark.selectionSha256,$Preflight.pairContract.sha256,
    $Model,$toolchainHash,$budgetHash,$environmentHash,$promptTemplateHash,$subjectHash,$manifestHash,$brainCoreHash,$memoryPolicyHash,$nativeHostHash
  ) -join "`n"))
  $manifest = Get-SuperBrainManifest $Root
  return [pscustomobject]@{
    scriptHash=$scriptHash
    manifest=$manifest
    manifestHash=$manifestHash
    brainCoreHash=$brainCoreHash
    memoryPolicyHash=$memoryPolicyHash
    endpointHash=$nativeHostHash
    toolchainHash=$toolchainHash
    budgetHash=$budgetHash
    environmentHash=$environmentHash
    promptTemplateHash=$promptTemplateHash
    subjectHash=$subjectHash
    configFingerprint=$configFingerprint
  }
}

function Get-ObjectiveBatchCaseSetSha256($Cases) {
  return Get-SuperBrainTextSha256 ((@($Cases | ForEach-Object { [string]$_.id }) -join "`n"))
}

function New-ObjectiveGenerationCheckpoint($Preflight, $Metadata, $OrderedCases) {
  $batches = New-Object Collections.ArrayList
  $batchIndex = 0
  for ($offset = 0; $offset -lt $OrderedCases.Count; $offset += $BatchSize) {
    $last = [Math]::Min($offset + $BatchSize - 1, $OrderedCases.Count - 1)
    $batchCases = @($OrderedCases[$offset..$last])
    [void]$batches.Add([pscustomobject]@{
      index=$batchIndex
      caseIds=@($batchCases | ForEach-Object { [string]$_.id })
      caseSetSha256=(Get-ObjectiveBatchCaseSetSha256 $batchCases)
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
    schema='super-brain.objective-answer-checkpoint.v1'
    status='active'
    createdAtUtc=(Get-Date).ToUniversalTime().ToString('o')
    updatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
    identity=[pscustomobject]@{
      inputSha256=$Preflight.inputSha256
      caseSetHash=$Preflight.caseSetHash
      pairContractSha256=$Preflight.pairContract.sha256
      configFingerprint=$Metadata.configFingerprint
      model=$Model
      reasoningEffort=$ReasoningEffort
      maxOutputTokens=$MaxOutputTokens
      timeoutSeconds=$TimeoutSeconds
      batchSize=$BatchSize
      maxBatchAttempts=$MaxBatchAttempts
      endpointSha256=$Metadata.endpointHash
      transportProbeReceiptSha256=$Metadata.transportProbeReceiptSha256
      superMemoryBrainEnabled=$Preflight.superMemoryBrainEnabled
    }
    batches=@($batches)
    completedAnswers=@()
    privacy=[pscustomobject]@{ privateCheckpointOnly=$true; credentialStored=$false; rawResponseStored=$false; referenceOrRubricSentToModel=$false }
  }
}

function Write-ObjectiveGenerationCheckpoint([string]$Path, $Checkpoint) {
  $Checkpoint.updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  Write-ObjectiveGeneratorJsonAtomic $Path $Checkpoint
}

function Get-ObjectiveCheckpointExpectedIdentity($Preflight, $Metadata) {
  return [ordered]@{
    inputSha256=$Preflight.inputSha256
    caseSetHash=$Preflight.caseSetHash
    pairContractSha256=$Preflight.pairContract.sha256
    configFingerprint=$Metadata.configFingerprint
    model=$Model
    reasoningEffort=$ReasoningEffort
    maxOutputTokens=$MaxOutputTokens
    timeoutSeconds=$TimeoutSeconds
    batchSize=$BatchSize
    maxBatchAttempts=$MaxBatchAttempts
    endpointSha256=$Metadata.endpointHash
    transportProbeReceiptSha256=$Metadata.transportProbeReceiptSha256
    superMemoryBrainEnabled=$Preflight.superMemoryBrainEnabled
  }
}

function Read-ObjectiveGenerationCheckpoint([string]$Path, $Preflight, $Metadata, $OrderedCases) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_MISSING' 'No checkpoint exists at the requested resume path.' }
  $checkpoint = Read-ObjectiveGeneratorJson $Path 'OBJECTIVE_CHECKPOINT_INVALID'
  if ([string]$checkpoint.schema -ne 'super-brain.objective-answer-checkpoint.v1' -or $null -eq $checkpoint.identity -or $null -eq $checkpoint.batches -or $null -eq $checkpoint.completedAnswers) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint schema or required state is invalid.'
  }
  foreach ($entry in (Get-ObjectiveCheckpointExpectedIdentity $Preflight $Metadata).GetEnumerator()) {
    if ($null -eq $checkpoint.identity.PSObject.Properties[$entry.Key] -or [string]$checkpoint.identity.PSObject.Properties[$entry.Key].Value -ne [string]$entry.Value) {
      Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_BINDING_MISMATCH' "Checkpoint does not match the current $($entry.Key)."
    }
  }
  $expectedBatchCount = [int][Math]::Ceiling($OrderedCases.Count / [double]$BatchSize)
  if (@($checkpoint.batches).Count -ne $expectedBatchCount) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint batch count is invalid.' }
  $expectedCompletedIds = @{}
  for ($index = 0; $index -lt $expectedBatchCount; $index++) {
    $batch = @($checkpoint.batches)[$index]
    $offset = $index * $BatchSize
    $last = [Math]::Min($offset + $BatchSize - 1, $OrderedCases.Count - 1)
    $expectedCases = @($OrderedCases[$offset..$last])
    if ([int]$batch.index -ne $index -or ((@($batch.caseIds) -join "`n") -ne (@($expectedCases | ForEach-Object { [string]$_.id }) -join "`n")) -or [string]$batch.caseSetSha256 -ne (Get-ObjectiveBatchCaseSetSha256 $expectedCases)) {
      Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint batch layout is invalid.'
    }
    if ([string]$batch.status -notin @('pending','complete','blocked','in_progress')) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint batch status is invalid.' }
    if ([int]$batch.attemptCount -lt 0 -or [int]$batch.attemptCount -gt 1) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint batch attempt count is invalid.' }
    if ([string]$batch.status -eq 'complete') {
      if ([int]$batch.attemptCount -ne 1 -or [string]::IsNullOrWhiteSpace([string]$batch.responseReceiptSha256) -or [string]$batch.responseModel -ne $Model) {
        Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Completed checkpoint batch evidence is invalid.'
      }
      foreach ($case in $expectedCases) { $expectedCompletedIds[[string]$case.id] = $true }
    } elseif ([string]$batch.status -eq 'pending') {
      if ([int]$batch.attemptCount -ne 0) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Pending checkpoint batch has an attempt.' }
    } elseif ([string]$batch.status -eq 'in_progress') {
      Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INDETERMINATE' 'A batch was marked in progress when execution stopped; it cannot be replayed automatically.'
    } else {
      Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_BLOCKED' 'A prior batch failed. Start a new controlled evaluation run instead of replaying it automatically.'
    }
  }
  $actualCompletedIds = @{}
  foreach ($answer in @($checkpoint.completedAnswers)) {
    $id = Get-ObjectiveRequiredText $answer 'id' 'OBJECTIVE_CHECKPOINT_INVALID' 160
    if ($actualCompletedIds.ContainsKey($id) -or -not $expectedCompletedIds.ContainsKey($id)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint completed answers do not match completed batches.' }
    [void](Get-ObjectiveRequiredText $answer 'answer' 'OBJECTIVE_CHECKPOINT_INVALID' 8000)
    if ([string](Get-ObjectiveRequiredText $answer 'responseModel' 'OBJECTIVE_CHECKPOINT_INVALID' 160) -ne $Model) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint answer model is invalid.' }
    $actualCompletedIds[$id] = $true
  }
  if ($actualCompletedIds.Count -ne $expectedCompletedIds.Count) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint completed answer count is invalid.' }
  foreach ($id in $expectedCompletedIds.Keys) { if (-not $actualCompletedIds.ContainsKey($id)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint is missing a completed answer.' } }
  $allComplete = @($checkpoint.batches | Where-Object { [string]$_.status -ne 'complete' }).Count -eq 0
  if ($allComplete -and [string]$checkpoint.status -ne 'complete') { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint completion state is invalid.' }
  if (-not $allComplete -and [string]$checkpoint.status -ne 'active') { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint active state is invalid.' }
  return $checkpoint
}

function Get-ObjectiveAnswerCasesFromCheckpoint($Preflight, $Checkpoint) {
  $answersById = @{}
  foreach ($entry in @($Checkpoint.completedAnswers)) { $answersById[[string]$entry.id] = $entry }
  $result = New-Object Collections.ArrayList
  foreach ($case in @($Preflight.cases.Values | Sort-Object id)) {
    $answer = $answersById[[string]$case.id]
    if ($null -eq $answer) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Checkpoint does not contain every answer.' }
    [void]$result.Add([pscustomobject]@{
      id=[string]$case.id
      prompt=[string]$case.prompt
      reference=[string]$case.reference
      rubric=[string]$case.rubric
      answer=[string]$answer.answer
      responseModel=[string]$answer.responseModel
    })
  }
  return @($result)
}

function Get-ObjectiveGeneratorConnection {
  $connection = Resolve-SuperBrainResponsesConnection -ExplicitResponsesUrl $ResponsesUrl -PrimaryResponsesUrlEnvironment 'SUPER_BRAIN_ANSWER_RESPONSES_URL' -ApiKeyEnvironment $ApiKeyEnv
  if ([string]::IsNullOrWhiteSpace([string]$connection.responsesUrl)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_API_URL_REQUIRED' 'Objective answer-generator Responses URL is required.' }
  if ([string]::IsNullOrWhiteSpace([string]$connection.apiKey)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_API_KEY_MISSING' "No objective answer-generator credential is available in $ApiKeyEnv." }
  return [pscustomobject]@{
    uri = [uri]$connection.responsesUrl
    apiKey = [string]$connection.apiKey
    endpointSource = [string]$connection.endpointSource
    credentialSource = [string]$connection.credentialSource
  }
}

function Get-ObjectiveAnswerInput([string]$Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $input = Read-ObjectiveGeneratorJson $fullPath 'OBJECTIVE_INPUT_REQUIRED'
  if ([string]$input.schema -ne 'super-brain.objective-answer-input.v1') { Throw-ObjectiveGeneratorError 'OBJECTIVE_INPUT_SCHEMA_INVALID' 'Unsupported objective answer-input schema.' }
  if ($null -eq $input.PSObject.Properties['benchmark'] -or $null -eq $input.benchmark) { Throw-ObjectiveGeneratorError 'OBJECTIVE_INPUT_BENCHMARK_MISSING' 'Benchmark metadata is required.' }
  if ($null -eq $input.PSObject.Properties['condition'] -or $null -eq $input.condition) { Throw-ObjectiveGeneratorError 'OBJECTIVE_INPUT_CONDITION_MISSING' 'Condition metadata is required.' }
  if ([string](Get-ObjectiveRequiredText $input.benchmark 'id' 'OBJECTIVE_INPUT_BENCHMARK_INVALID' 80) -ne 'longmemeval') { Throw-ObjectiveGeneratorError 'OBJECTIVE_BENCHMARK_UNSUPPORTED' 'This launcher currently accepts LongMemEval only.' }
  if ([string](Get-ObjectiveRequiredText $input.benchmark 'variant' 'OBJECTIVE_INPUT_BENCHMARK_INVALID' 80) -ne 's_cleaned') { Throw-ObjectiveGeneratorError 'OBJECTIVE_BENCHMARK_VARIANT_INVALID' 'Fresh v14 answer artifacts must use benchmarkVariant=s_cleaned.' }
  $corpusHash = Get-ObjectiveSha256 (Get-ObjectiveRequiredText $input.benchmark 'corpusSha256' 'OBJECTIVE_INPUT_BENCHMARK_INVALID' 64) 'benchmark.corpusSha256'
  $harnessHash = Get-ObjectiveSha256 (Get-ObjectiveRequiredText $input.benchmark 'harnessSha256' 'OBJECTIVE_INPUT_BENCHMARK_INVALID' 64) 'benchmark.harnessSha256'
  $selectionHash = Get-ObjectiveSha256 (Get-ObjectiveRequiredText $input.benchmark 'selectionSha256' 'OBJECTIVE_INPUT_BENCHMARK_INVALID' 64) 'benchmark.selectionSha256'
  $benchmark = [pscustomobject]@{ id='longmemeval'; variant='s_cleaned'; corpusSha256=$corpusHash; harnessSha256=$harnessHash; selectionSha256=$selectionHash }
  $pairContract = Get-ObjectivePairContract $input $benchmark
  $enabled = Get-ObjectiveRequiredBoolean $input.condition 'superMemoryBrainEnabled' 'OBJECTIVE_INPUT_CONDITION_INVALID'
  $byId = @{}
  foreach ($rawCase in @($input.cases)) {
    $id = Get-ObjectiveRequiredText $rawCase 'id' 'OBJECTIVE_INPUT_CASE_INVALID' 160
    if ($byId.ContainsKey($id)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_INPUT_CASE_DUPLICATE' "Duplicate case id: $id" }
    $context = Get-ObjectiveOptionalText $rawCase 'retrievedContext' 60000
    if (-not $enabled -and -not [string]::IsNullOrWhiteSpace($context)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_BASELINE_CONTEXT_NOT_EMPTY' 'Baseline input must have an empty retrievedContext for every case.' }
    $byId[$id] = [pscustomobject]@{
      id = $id
      prompt = Get-ObjectiveRequiredText $rawCase 'prompt' 'OBJECTIVE_INPUT_CASE_INVALID' 12000
      reference = Get-ObjectiveRequiredText $rawCase 'reference' 'OBJECTIVE_INPUT_CASE_INVALID' 12000
      rubric = Get-ObjectiveRequiredText $rawCase 'rubric' 'OBJECTIVE_INPUT_CASE_INVALID' 12000
      retrievedContext = $context
      shapeHash = Get-ObjectiveCaseShapeHash $rawCase
    }
  }
  if ($byId.Count -lt 1) { Throw-ObjectiveGeneratorError 'OBJECTIVE_INPUT_CASES_EMPTY' 'Answer input has no cases.' }
  $caseSetHash = Get-ObjectiveCaseSetHash $byId
  if ($caseSetHash -ne [string]$pairContract.caseSetHash -or $byId.Count -ne [int]$pairContract.caseCount) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_PAIR_CONTRACT_CASE_SET_MISMATCH' 'Answer input cases do not match the shared pair contract.'
  }
  return [pscustomobject]@{
    path = $fullPath
    inputSha256 = Get-ObjectiveFileSha256 $fullPath 'OBJECTIVE_INPUT_HASH_FAILED'
    benchmark = $benchmark
    pairContract = $pairContract
    superMemoryBrainEnabled = $enabled
    cases = $byId
    caseSetHash = $caseSetHash
  }
}

function Get-ObjectiveNativeIdentity([string]$Value, [string]$Name) {
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 160 -or $text -notmatch '^[A-Za-z0-9._:-]+$') {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_IDENTITY_INVALID' "Native agent $Name is invalid."
  }
  return $text
}

function Get-ObjectiveNativeFileName([int]$Index, [string]$Suffix) {
  return ('batch-{0:D4}{1}' -f $Index, $Suffix)
}

function ConvertTo-ObjectiveNativeCase($Case) {
  return [pscustomobject]([ordered]@{
    id = Get-ObjectiveRequiredText $Case 'id' 'OBJECTIVE_NATIVE_CASE_INVALID' 160
    prompt = Get-ObjectiveRequiredText $Case 'prompt' 'OBJECTIVE_NATIVE_CASE_INVALID' 12000
    retrievedContext = Get-ObjectiveOptionalText $Case 'retrievedContext' 60000
  })
}

function Get-ObjectiveNativeBatchDescriptor($Batch) {
  return [ordered]@{
    schema = [string]$Batch.schema
    workflow = [string]$Batch.workflow
    manifestId = [string]$Batch.manifestId
    inputSha256 = [string]$Batch.inputSha256
    caseSetHash = [string]$Batch.caseSetHash
    pairContractSha256 = [string]$Batch.pairContractSha256
    modelId = [string]$Batch.modelId
    superMemoryBrainEnabled = $Batch.superMemoryBrainEnabled
    batchIndex = [int]$Batch.batchIndex
    responseFile = [string]$Batch.responseFile
    cases = @($Batch.cases)
    privacy = [ordered]@{
      referenceOrRubricSentToAgent = $Batch.privacy.referenceOrRubricSentToAgent
      rawExpectedDataStored = $Batch.privacy.rawExpectedDataStored
      rawModelTranscriptStored = $Batch.privacy.rawModelTranscriptStored
    }
  }
}

function Get-ObjectiveNativeBatchHash($Batch) {
  return Get-SuperBrainTextSha256 ((Get-ObjectiveNativeBatchDescriptor $Batch | ConvertTo-Json -Depth 24 -Compress))
}

function Get-ObjectiveNativeManifestDescriptor($Manifest) {
  $batches = @($Manifest.batches | Sort-Object index | ForEach-Object {
    [ordered]@{
      index = [int]$_.index
      batchId = [string]$_.batchId
      batchHash = [string]$_.batchHash
      batchFile = [string]$_.batchFile
      responseFile = [string]$_.responseFile
      caseIds = @($_.caseIds)
    }
  })
  return [ordered]@{
    schema = [string]$Manifest.schema
    workflow = [string]$Manifest.workflow
    manifestId = [string]$Manifest.manifestId
    inputSha256 = [string]$Manifest.inputSha256
    caseSetHash = [string]$Manifest.caseSetHash
    pairContractSha256 = [string]$Manifest.pairContractSha256
    modelId = [string]$Manifest.modelId
    superMemoryBrainEnabled = $Manifest.superMemoryBrainEnabled
    batchSize = [int]$Manifest.batchSize
    batchCount = [int]$Manifest.batchCount
    batchDirectoryName = [string]$Manifest.batchDirectoryName
    batches = $batches
    privacy = [ordered]@{
      referenceOrRubricSentToAgent = $Manifest.privacy.referenceOrRubricSentToAgent
      rawExpectedDataStored = $Manifest.privacy.rawExpectedDataStored
      rawModelTranscriptStored = $Manifest.privacy.rawModelTranscriptStored
    }
  }
}

function Get-ObjectiveNativeManifestHash($Manifest) {
  return Get-SuperBrainTextSha256 ((Get-ObjectiveNativeManifestDescriptor $Manifest | ConvertTo-Json -Depth 24 -Compress))
}

function Assert-ObjectiveNativePrivacy($Privacy, [string]$Code) {
  if ($null -eq $Privacy) { Throw-ObjectiveGeneratorError $Code 'Native batch privacy contract is missing.' }
  $allowedFields = @('referenceOrRubricSentToAgent','rawExpectedDataStored','rawModelTranscriptStored')
  $actualFields = @($Privacy.PSObject.Properties.Name)
  if (@($actualFields | Where-Object { $_ -notin $allowedFields }).Count -gt 0 -or @($allowedFields | Where-Object { $_ -notin $actualFields }).Count -gt 0) {
    Throw-ObjectiveGeneratorError $Code 'Native batch privacy contract is invalid.'
  }
  if ((Get-ObjectiveRequiredBoolean $Privacy 'referenceOrRubricSentToAgent' $Code) -ne $false -or
      (Get-ObjectiveRequiredBoolean $Privacy 'rawExpectedDataStored' $Code) -ne $false -or
      (Get-ObjectiveRequiredBoolean $Privacy 'rawModelTranscriptStored' $Code) -ne $false) {
    Throw-ObjectiveGeneratorError $Code 'Native batch must attest that references, rubrics, expected data, and raw transcripts are absent.'
  }
}

function Assert-ObjectiveNativeManifest($Manifest, $Preflight) {
  if ($null -eq $Manifest) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest is missing.' }
  $allowedFields = @('schema','workflow','manifestId','inputSha256','caseSetHash','pairContractSha256','modelId','superMemoryBrainEnabled','batchSize','batchCount','batchDirectoryName','batches','manifestHash','privacy')
  $actualFields = @($Manifest.PSObject.Properties.Name)
  if (@($actualFields | Where-Object { $_ -notin $allowedFields }).Count -gt 0 -or @($allowedFields | Where-Object { $_ -notin $actualFields }).Count -gt 0) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest must contain only the blinded export contract.'
  }
  if ([string]$Manifest.schema -ne 'super-brain.objective-native-answer-manifest.v1' -or [string]$Manifest.workflow -ne 'longmemeval_s_cleaned_paired_blind_answer') {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest schema is invalid.'
  }
  [void](Get-ObjectiveNativeIdentity ([string]$Manifest.manifestId) 'manifest id')
  $manifestEnabled = Get-ObjectiveRequiredBoolean $Manifest 'superMemoryBrainEnabled' 'OBJECTIVE_NATIVE_MANIFEST_INVALID'
  if ([string]$Manifest.inputSha256 -ne [string]$Preflight.inputSha256 -or [string]$Manifest.caseSetHash -ne [string]$Preflight.caseSetHash -or
      [string]$Manifest.pairContractSha256 -ne [string]$Preflight.pairContract.sha256 -or [string]$Manifest.modelId -ne $Model -or
      $manifestEnabled -ne [bool]$Preflight.superMemoryBrainEnabled -or [int]$Manifest.batchSize -ne $BatchSize) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_BINDING_MISMATCH' 'Native manifest does not bind the current input, condition, model, or budget.'
  }
  Assert-ObjectiveNativePrivacy $Manifest.privacy 'OBJECTIVE_NATIVE_MANIFEST_INVALID'
  $directoryName = Get-ObjectiveRequiredText $Manifest 'batchDirectoryName' 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 260
  if ([IO.Path]::GetFileName($directoryName) -ne $directoryName) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest batch directory name is invalid.' }
  $orderedCases = @($Preflight.cases.Values | Sort-Object id)
  $expectedBatchCount = [int][Math]::Ceiling($orderedCases.Count / [double]$BatchSize)
  if ([int]$Manifest.batchCount -ne $expectedBatchCount -or @($Manifest.batches).Count -ne $expectedBatchCount) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest batch count is invalid.'
  }
  if ([string]$Manifest.manifestHash -ne (Get-ObjectiveNativeManifestHash $Manifest)) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_HASH_MISMATCH' 'Native manifest hash is invalid.'
  }
  $seenBatchIds = @{}
  for ($index = 0; $index -lt $expectedBatchCount; $index++) {
    $entry = @($Manifest.batches | Where-Object { [int]$_.index -eq $index })
    if ($entry.Count -ne 1) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest batch indexes are invalid.' }
    $entry = $entry[0]
    $entryFields = @($entry.PSObject.Properties.Name)
    $allowedEntryFields = @('index','batchId','batchHash','batchFile','responseFile','caseIds')
    if (@($entryFields | Where-Object { $_ -notin $allowedEntryFields }).Count -gt 0 -or @($allowedEntryFields | Where-Object { $_ -notin $entryFields }).Count -gt 0) {
      Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest batch entry is invalid.'
    }
    $batchId = Get-ObjectiveNativeIdentity ([string]$entry.batchId) 'batch id'
    if ($seenBatchIds.ContainsKey($batchId)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest has duplicate batch ids.' }
    $seenBatchIds[$batchId] = $true
    if ($batchId -ne ([string]$Manifest.manifestId + ':' + $index)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest batch id is invalid.' }
    if ([string]$entry.batchHash -notmatch '^[a-f0-9]{64}$') { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest batch hash is invalid.' }
    $expectedBatchFile = Get-ObjectiveNativeFileName $index '.json'
    $expectedResponseFile = Get-ObjectiveNativeFileName $index '.response.json'
    if ([string]$entry.batchFile -ne $expectedBatchFile -or [string]$entry.responseFile -ne $expectedResponseFile) {
      Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest batch file mapping is invalid.'
    }
    $offset = $index * $BatchSize
    $last = [Math]::Min($offset + $BatchSize - 1, $orderedCases.Count - 1)
    $expectedIds = @($orderedCases[$offset..$last] | ForEach-Object { [string]$_.id })
    if ((@($entry.caseIds) -join "`n") -ne ($expectedIds -join "`n")) {
      Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_MANIFEST_INVALID' 'Native manifest case layout is invalid.'
    }
  }
  return $Manifest
}

function Assert-ObjectiveNativeBatch($Batch, $Entry, $ExpectedCases, $Preflight, $Manifest) {
  if ($null -eq $Batch) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_BATCH_INVALID' 'Native batch is missing.' }
  $allowedFields = @('schema','workflow','manifestId','inputSha256','caseSetHash','pairContractSha256','modelId','superMemoryBrainEnabled','batchIndex','responseFile','cases','batchHash','privacy')
  $actualFields = @($Batch.PSObject.Properties.Name)
  if (@($actualFields | Where-Object { $_ -notin $allowedFields }).Count -gt 0 -or @($allowedFields | Where-Object { $_ -notin $actualFields }).Count -gt 0) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_BATCH_INVALID' 'Native batch must contain only the blinded batch contract.'
  }
  $batchEnabled = Get-ObjectiveRequiredBoolean $Batch 'superMemoryBrainEnabled' 'OBJECTIVE_NATIVE_BATCH_INVALID'
  if ([string]$Batch.schema -ne 'super-brain.objective-native-answer-batch.v1' -or [string]$Batch.workflow -ne 'longmemeval_s_cleaned_paired_blind_answer' -or
      [string]$Batch.manifestId -ne [string]$Manifest.manifestId -or [string]$Batch.inputSha256 -ne [string]$Preflight.inputSha256 -or
      [string]$Batch.caseSetHash -ne [string]$Preflight.caseSetHash -or [string]$Batch.pairContractSha256 -ne [string]$Preflight.pairContract.sha256 -or
      [string]$Batch.modelId -ne $Model -or $batchEnabled -ne [bool]$Preflight.superMemoryBrainEnabled -or
      [int]$Batch.batchIndex -ne [int]$Entry.index -or [string]$Batch.responseFile -ne [string]$Entry.responseFile) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_BATCH_BINDING_MISMATCH' 'Native batch does not bind the current manifest and answer input.'
  }
  Assert-ObjectiveNativePrivacy $Batch.privacy 'OBJECTIVE_NATIVE_BATCH_INVALID'
  if ([string]$Batch.batchHash -ne [string]$Entry.batchHash -or [string]$Batch.batchHash -ne (Get-ObjectiveNativeBatchHash $Batch)) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_BATCH_HASH_MISMATCH' 'Native batch hash is invalid.'
  }
  $expectedProjection = @($ExpectedCases | ForEach-Object { ConvertTo-ObjectiveNativeCase $_ })
  $actualCases = @($Batch.cases | Sort-Object id)
  if ($actualCases.Count -ne $expectedProjection.Count) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_BATCH_CASE_SET_MISMATCH' 'Native batch case coverage is invalid.' }
  $expectedProjection = @($expectedProjection | Sort-Object id)
  for ($index = 0; $index -lt $expectedProjection.Count; $index++) {
    if (($expectedProjection[$index] | ConvertTo-Json -Depth 16 -Compress) -ne ($actualCases[$index] | ConvertTo-Json -Depth 16 -Compress)) {
      Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_BATCH_CASE_SET_MISMATCH' 'Native batch contains data outside the blinded input projection.'
    }
  }
}

function Read-ObjectiveNativeResponse($Response, $Batch, $ExpectedCases) {
  if ($null -eq $Response) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_RESPONSE_INVALID' 'Native answer response is missing.' }
  $allowedFields = @('schema','batchId','batchHash','hostAgentId','hostDispatchId','cases')
  $actualFields = @($Response.PSObject.Properties.Name)
  if (@($actualFields | Where-Object { $_ -notin $allowedFields }).Count -gt 0 -or @($allowedFields | Where-Object { $_ -notin $actualFields }).Count -gt 0 -or
      [string]$Response.schema -ne 'super-brain.objective-host-native-agent-response.v1' -or [string]$Response.batchId -ne (([string]$Batch.manifestId) + ':' + ([string]$Batch.batchIndex)) -or
      [string]$Response.batchHash -ne [string]$Batch.batchHash) {
    Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_RESPONSE_INVALID' 'Native response must contain only one bound batch answer payload.'
  }
  $agentId = Get-ObjectiveNativeIdentity ([string]$Response.hostAgentId) 'id'
  $dispatchId = Get-ObjectiveNativeIdentity ([string]$Response.hostDispatchId) 'dispatch id'
  $normalizedPayload = [pscustomobject]@{ cases=@($Response.cases) } | ConvertTo-Json -Depth 16 -Compress
  $answers = @(ConvertFrom-ObjectiveAnswerBatch $normalizedPayload $ExpectedCases $Model)
  return [pscustomobject]@{ answers=$answers; hostAgentId=$agentId; hostDispatchId=$dispatchId }
}

function Export-ObjectiveNativeBatches {
  if (-not $Apply) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_EXPORT_APPLY_REQUIRED' 'Native answer batch export requires explicit -Apply.' }
  $preflight = Get-ObjectiveAnswerInput $AnswerInputPath
  Assert-ObjectiveGenerationBudget $preflight.pairContract
  $output = Get-ObjectivePrivateOutputPath $OutputPath
  $batchDirectoryName = [IO.Path]::GetFileName($output) + '.batches'
  $batchDirectory = Get-ObjectiveNewPrivateDirectoryPath (Join-Path (Split-Path -Parent $output) $batchDirectoryName) 'OBJECTIVE_NATIVE_BATCH_DIRECTORY_EXISTS' 'native batch'
  $orderedCases = @($preflight.cases.Values | Sort-Object id)
  $manifestId = 'objective-native-' + [guid]::NewGuid().ToString('N')
  $batches = New-Object Collections.ArrayList
  $batchIndex = 0
  for ($offset = 0; $offset -lt $orderedCases.Count; $offset += $BatchSize) {
    $last = [Math]::Min($offset + $BatchSize - 1, $orderedCases.Count - 1)
    $batchCases = @($orderedCases[$offset..$last])
    $batchFile = Get-ObjectiveNativeFileName $batchIndex '.json'
    $responseFile = Get-ObjectiveNativeFileName $batchIndex '.response.json'
    $batch = [pscustomobject]([ordered]@{
      schema='super-brain.objective-native-answer-batch.v1'
      workflow='longmemeval_s_cleaned_paired_blind_answer'
      manifestId=$manifestId
      inputSha256=[string]$preflight.inputSha256
      caseSetHash=[string]$preflight.caseSetHash
      pairContractSha256=[string]$preflight.pairContract.sha256
      modelId=$Model
      superMemoryBrainEnabled=[bool]$preflight.superMemoryBrainEnabled
      batchIndex=$batchIndex
      responseFile=$responseFile
      cases=@($batchCases | ForEach-Object { ConvertTo-ObjectiveNativeCase $_ })
      batchHash=''
      privacy=[pscustomobject]@{ referenceOrRubricSentToAgent=$false; rawExpectedDataStored=$false; rawModelTranscriptStored=$false }
    })
    $batch.batchHash = Get-ObjectiveNativeBatchHash $batch
    [void]$batches.Add([pscustomobject]([ordered]@{
      index=$batchIndex; batchId=$manifestId + ':' + $batchIndex; batchHash=[string]$batch.batchHash; batchFile=$batchFile; responseFile=$responseFile; caseIds=@($batchCases | ForEach-Object { [string]$_.id })
    }))
    Write-ObjectiveGeneratorJsonAtomic (Join-Path $batchDirectory $batchFile) $batch
    $batchIndex++
  }
  $manifest = [pscustomobject]([ordered]@{
    schema='super-brain.objective-native-answer-manifest.v1'
    workflow='longmemeval_s_cleaned_paired_blind_answer'
    manifestId=$manifestId
    inputSha256=[string]$preflight.inputSha256
    caseSetHash=[string]$preflight.caseSetHash
    pairContractSha256=[string]$preflight.pairContract.sha256
    modelId=$Model
    superMemoryBrainEnabled=[bool]$preflight.superMemoryBrainEnabled
    batchSize=$BatchSize
    batchCount=$batches.Count
    batchDirectoryName=$batchDirectoryName
    batches=@($batches)
    manifestHash=''
    privacy=[pscustomobject]@{ referenceOrRubricSentToAgent=$false; rawExpectedDataStored=$false; rawModelTranscriptStored=$false }
  })
  $manifest.manifestHash = Get-ObjectiveNativeManifestHash $manifest
  [void](Assert-ObjectiveNativeManifest $manifest $preflight)
  Write-ObjectiveGeneratorJsonAtomic $output $manifest
  return [pscustomobject]@{
    ok=$true; action='ExportNative'; schema='super-brain.objective-native-answer-export-result.v1'; status='native_batches_exported_private'
    outputPath=$output; outputSha256=(Get-ObjectiveFileSha256 $output 'OBJECTIVE_OUTPUT_HASH_FAILED'); batchDirectory=$batchDirectory; manifestId=$manifestId; manifestHash=[string]$manifest.manifestHash
    batchCount=$batches.Count; caseCount=$orderedCases.Count; batchSize=$BatchSize; superMemoryBrainEnabled=[bool]$preflight.superMemoryBrainEnabled; model=$Model
    referenceOrRubricSentToAgent=$false; expectedAnswerDataAvailable=$false; rawModelTranscriptStored=$false
  }
}

function Import-ObjectiveNativeBatches {
  if (-not $Apply) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_IMPORT_APPLY_REQUIRED' 'Native answer batch import requires explicit -Apply.' }
  $preflight = Get-ObjectiveAnswerInput $AnswerInputPath
  Assert-ObjectiveGenerationBudget $preflight.pairContract
  $output = Get-ObjectivePrivateOutputPath $OutputPath
  $manifestPath = Get-ObjectiveExistingPrivateArtifactPath $NativeManifestPath 'OBJECTIVE_NATIVE_MANIFEST_MISSING' 'native manifest'
  $responseDirectory = Get-ObjectiveExistingPrivateDirectoryPath $NativeResponseDirectory 'OBJECTIVE_NATIVE_RESPONSE_DIRECTORY_MISSING' 'native response'
  $manifest = Read-ObjectiveGeneratorJson $manifestPath 'OBJECTIVE_NATIVE_MANIFEST_INVALID'
  [void](Assert-ObjectiveNativeManifest $manifest $preflight)
  $batchDirectory = Get-ObjectiveExistingPrivateDirectoryPath (Join-Path (Split-Path -Parent $manifestPath) ([string]$manifest.batchDirectoryName)) 'OBJECTIVE_NATIVE_BATCH_DIRECTORY_MISSING' 'native batch'
  $orderedCases = @($preflight.cases.Values | Sort-Object id)
  $answers = New-Object Collections.ArrayList
  $receiptHashes = New-Object Collections.ArrayList
  $dispatchIds = @{}
  foreach ($entry in @($manifest.batches | Sort-Object index)) {
    $index = [int]$entry.index
    $offset = $index * $BatchSize
    $last = [Math]::Min($offset + $BatchSize - 1, $orderedCases.Count - 1)
    $expectedCases = @($orderedCases[$offset..$last])
    $batchPath = Get-ObjectiveExistingPrivateArtifactPath (Join-Path $batchDirectory ([string]$entry.batchFile)) 'OBJECTIVE_NATIVE_BATCH_MISSING' 'native batch'
    $batch = Read-ObjectiveGeneratorJson $batchPath 'OBJECTIVE_NATIVE_BATCH_INVALID'
    Assert-ObjectiveNativeBatch $batch $entry $expectedCases $preflight $manifest
    $responsePath = Get-ObjectiveExistingPrivateArtifactPath (Join-Path $responseDirectory ([string]$entry.responseFile)) 'OBJECTIVE_NATIVE_RESPONSE_MISSING' 'native response'
    $response = Read-ObjectiveGeneratorJson $responsePath 'OBJECTIVE_NATIVE_RESPONSE_INVALID'
    $nativeResponse = Read-ObjectiveNativeResponse $response $batch $expectedCases
    $dispatchKey = $nativeResponse.hostAgentId + "`n" + $nativeResponse.hostDispatchId
    if ($dispatchIds.ContainsKey($dispatchKey)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_DISPATCH_DUPLICATE' 'A host-native dispatch may answer only one blinded batch.' }
    $dispatchIds[$dispatchKey] = $true
    foreach ($answer in @($nativeResponse.answers)) { [void]$answers.Add($answer) }
    $receipt = [ordered]@{
      schema='super-brain.objective-native-agent-dispatch-receipt.v1'; manifestId=[string]$manifest.manifestId; batchId=[string]$entry.batchId; batchHash=[string]$entry.batchHash
      hostAgentId=$nativeResponse.hostAgentId; hostDispatchId=$nativeResponse.hostDispatchId; responseSha256=(Get-ObjectiveFileSha256 $responsePath 'OBJECTIVE_NATIVE_RESPONSE_HASH_FAILED'); caseCount=@($nativeResponse.answers).Count
      referenceOrRubricSentToAgent=$false; rawModelTranscriptStored=$false
    }
    [void]$receiptHashes.Add((Get-SuperBrainTextSha256 ($receipt | ConvertTo-Json -Depth 16 -Compress)))
  }
  if ($answers.Count -ne $orderedCases.Count) { Throw-ObjectiveGeneratorError 'OBJECTIVE_NATIVE_RESPONSE_COVERAGE_INVALID' 'Native responses do not cover every answer-input case.' }
  $answerCases = @($answers | Sort-Object id)
  $metadata = Get-ObjectiveNativeGenerationMetadata $preflight
  $dispatchReceipt = Get-SuperBrainTextSha256 ((@($receiptHashes) | Sort-Object) -join "`n")
  $responseReceipt = Get-SuperBrainTextSha256 ([string]$preflight.inputSha256 + "`n" + [string]$manifest.manifestHash + "`n" + $dispatchReceipt)
  $artifact = [pscustomobject]@{
    schema='super-brain.objective-answer-artifact.v1'
    status='answers_complete_private'
    createdAt=(Get-Date).ToString('o')
    caseSetHash=$preflight.caseSetHash
    generator=[pscustomobject]@{
      generatorId='super-brain.objective-native-agent-importer'; generatorSha256=$metadata.scriptHash
      runId='objective-native-' + $responseReceipt.Substring(0,32); executionId='objective-native-execution-' + $responseReceipt.Substring(32,24)
      modelId=$Model; modelVersion=$Model; requestedModelId=$Model; reportedModelId=$Model; benchmarkVariant='s_cleaned'
      responseCount=@($answerCases).Count; responseModelEvidenceSha256=(Get-ObjectiveResponseModelEvidenceHash @($answerCases))
      toolchainHash=$metadata.toolchainHash; budgetHash=$metadata.budgetHash; environmentHash=$metadata.environmentHash; promptTemplateHash=$metadata.promptTemplateHash
      packageVersion=[string]$metadata.manifest.version; subjectHash=$metadata.subjectHash; packageManifestSha256=$metadata.manifestHash; brainCoreSha256=$metadata.brainCoreHash; memoryPolicySha256=$metadata.memoryPolicyHash
      corpusHash=$preflight.benchmark.corpusSha256; harnessHash=$preflight.benchmark.harnessSha256; selectionSha256=$preflight.benchmark.selectionSha256; pairContractSha256=$preflight.pairContract.sha256; configFingerprint=$metadata.configFingerprint
      independentExecution=$true; superMemoryBrainEnabled=$preflight.superMemoryBrainEnabled; inputSha256=$preflight.inputSha256; endpointSha256=$metadata.endpointHash
      responseReceiptSha256=$responseReceipt; responseAttemptCount=@($manifest.batches).Count; transportProbeReceiptSha256=''; rawResponseStored=$false; referenceOrRubricSentToModel=$false
      hostedNativeAgent=$true; modelIdentityVerified=$true; nativeManifestSha256=$manifest.manifestHash; hostDispatchReceiptSha256=$dispatchReceipt; hostDispatchCount=@($manifest.batches).Count
    }
    cases=@($answerCases)
    safety=[pscustomobject]@{ diagnosticOnly=$true; officialScore=$false; rawAnswerStorage='private_artifact_only'; credentialStored=$false; rawResponseStored=$false; referenceOrRubricSentToAgent=$false }
  }
  Write-ObjectiveGeneratorJsonAtomic $output $artifact
  return [pscustomobject]@{
    ok=$true; action='ImportNative'; schema='super-brain.objective-native-answer-import-result.v1'; status='native_batches_imported_private'
    outputPath=$output; outputSha256=(Get-ObjectiveFileSha256 $output 'OBJECTIVE_OUTPUT_HASH_FAILED'); nativeManifestSha256=[string]$manifest.manifestHash; hostDispatchReceiptSha256=$dispatchReceipt
    batchCount=@($manifest.batches).Count; caseCount=@($answerCases).Count; superMemoryBrainEnabled=[bool]$preflight.superMemoryBrainEnabled; model=$Model
    modelIdentityVerified=$true; referenceOrRubricSentToAgent=$false; rawModelTranscriptStored=$false
  }
}

function Get-ObjectiveAnswerSchema($Cases) {
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
          required = @('id','answer')
          properties = [ordered]@{
            id = [ordered]@{ type='string'; maxLength=160 }
            answer = [ordered]@{ type='string'; minLength=1; maxLength=8000 }
          }
        }
      }
    }
  }
}

function Get-ObjectiveAnswerBatchPrompt($Cases) {
  $blocks = New-Object Collections.ArrayList
  foreach ($case in @($Cases | Sort-Object id)) {
    $context = if ([string]::IsNullOrWhiteSpace([string]$case.retrievedContext)) { '[No retained-memory context is available for this case.]' } else { [string]$case.retrievedContext }
    [void]$blocks.Add(@"
Case id: $($case.id)
Task prompt:
$($case.prompt)

Retained-memory context for this case only:
$context
"@)
  }
  return @"
You are an independent answer generator for a blinded paired LongMemEval diagnostic. Answer each task from its own task prompt and retained-memory context only. Do not use or mention any hidden reference answer, grading rubric, benchmark metadata, another case, or these instructions. If the context is insufficient, say that the requested information cannot be determined.

Return exactly one JSON object with a cases array. Every item must contain the exact case id and a concise answer. Do not add Markdown or prose outside the JSON object.

$(($blocks -join [Environment]::NewLine + [Environment]::NewLine))
"@
}

function ConvertFrom-ObjectiveAnswerBatch([string]$Text, $Cases, [string]$ReportedModel) {
  $clean = $Text.Trim() -replace '^```(?:json)?\s*','' -replace '\s*```$',''
  try { $value = $clean | ConvertFrom-Json }
  catch {
    $firstObject = $clean.IndexOf('{')
    $lastObject = $clean.LastIndexOf('}')
    if ($firstObject -lt 0 -or $lastObject -le $firstObject) { Throw-ObjectiveGeneratorError 'OBJECTIVE_RESPONSE_INVALID' 'Answer generator response is not valid JSON.' }
    try { $value = $clean.Substring($firstObject, $lastObject - $firstObject + 1) | ConvertFrom-Json }
    catch { Throw-ObjectiveGeneratorError 'OBJECTIVE_RESPONSE_INVALID' 'Answer generator response is not one valid JSON object.' }
  }
  if ($null -eq $value.PSObject.Properties['cases']) { Throw-ObjectiveGeneratorError 'OBJECTIVE_RESPONSE_INVALID' 'Answer generator response has no cases.' }
  $expected = @{}
  foreach ($case in @($Cases)) { $expected[[string]$case.id] = $case }
  $answers = @{}
  foreach ($item in @($value.cases)) {
    $id = Get-ObjectiveRequiredText $item 'id' 'OBJECTIVE_RESPONSE_INVALID' 160
    $answer = Get-ObjectiveRequiredText $item 'answer' 'OBJECTIVE_RESPONSE_INVALID' 8000
    if ($answers.ContainsKey($id) -or -not $expected.ContainsKey($id)) { Throw-ObjectiveGeneratorError 'OBJECTIVE_RESPONSE_INVALID' 'Answer generator response has invalid case ids.' }
    $case = $expected[$id]
    $answers[$id] = [pscustomobject]@{
      id = $id
      prompt = [string]$case.prompt
      reference = [string]$case.reference
      rubric = [string]$case.rubric
      answer = $answer
      responseModel = $ReportedModel
    }
  }
  if ($answers.Count -ne $expected.Count) { Throw-ObjectiveGeneratorError 'OBJECTIVE_RESPONSE_INVALID' 'Answer generator response does not cover every case exactly once.' }
  return @($answers.Keys | Sort-Object | ForEach-Object { $answers[$_] })
}

function Get-ObjectiveGeneratorStatus {
  $connection = Resolve-SuperBrainResponsesConnection -ExplicitResponsesUrl $ResponsesUrl -PrimaryResponsesUrlEnvironment 'SUPER_BRAIN_ANSWER_RESPONSES_URL' -ApiKeyEnvironment $ApiKeyEnv
  $urlConfigured = -not [string]::IsNullOrWhiteSpace([string]$connection.responsesUrl)
  $keyConfigured = -not [string]::IsNullOrWhiteSpace([string]$connection.apiKey)
  return [pscustomobject]@{
    ok = $true
    action = 'Status'
    schema = 'super-brain.objective-answer-generator-status.v1'
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

function Invoke-ObjectiveGeneratorProbe {
  if (-not $Apply) { Throw-ObjectiveGeneratorError 'PROBE_APPLY_REQUIRED' 'Objective answer-generator probing requires explicit -Apply.' }
  $connection = Get-ObjectiveGeneratorConnection
  $probe = Invoke-SuperBrainResponsesProbe -Uri $connection.uri -ApiKey $connection.apiKey -Model $Model -ReasoningEffort $ReasoningEffort -RequestInput 'Reply exactly with OK.' -MaxOutputTokens 64 -TimeoutSeconds $TimeoutSeconds -MaxAttempts $ProbeMaxAttempts -RetryDelayMilliseconds $ProbeRetryDelayMilliseconds
  $result = $probe.result
  [void](Get-SuperBrainResponsesId $result.response)
  $receipt = Write-SuperBrainResponsesTransportProbeReceipt -Scope 'objective-answer' -Uri $connection.uri -Model $Model -ReasoningEffort $ReasoningEffort
  return [pscustomobject]@{
    ok = $true
    action = 'Probe'
    schema = 'super-brain.objective-answer-generator-probe.v1'
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

function Invoke-ObjectiveAnswerArtifactGeneration {
  if (-not $Apply) { Throw-ObjectiveGeneratorError 'GENERATE_APPLY_REQUIRED' 'Objective answer artifact generation requires explicit -Apply.' }
  $preflight = Get-ObjectiveAnswerInput $AnswerInputPath
  $output = Get-ObjectivePrivateOutputPath $OutputPath
  Assert-ObjectiveGenerationBudget $preflight.pairContract
  $connection = Get-ObjectiveGeneratorConnection
  $transportProbe = Assert-SuperBrainResponsesTransportProbeReceipt -Scope 'objective-answer' -Uri $connection.uri -Model $Model -ReasoningEffort $ReasoningEffort
  $orderedCases = @($preflight.cases.Values | Sort-Object id)
  $metadata = Get-ObjectiveGenerationMetadata $preflight $connection $transportProbe
  $checkpointPath = Get-ObjectivePrivateCheckpointPath $output $CheckpointPath
  $checkpoint = if ($Resume) {
    Read-ObjectiveGenerationCheckpoint $checkpointPath $preflight $metadata $orderedCases
  } else {
    if (Test-Path -LiteralPath $checkpointPath -PathType Leaf) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_EXISTS' 'A checkpoint already exists. Use -Resume after checking its state.' }
    $fresh = New-ObjectiveGenerationCheckpoint $preflight $metadata $orderedCases
    Write-ObjectiveGenerationCheckpoint $checkpointPath $fresh
    $fresh
  }
  $newBatchCount = 0
  for ($batchIndex = 0; $batchIndex -lt @($checkpoint.batches).Count; $batchIndex++) {
    $batch = @($checkpoint.batches)[$batchIndex]
    if ([string]$batch.status -eq 'complete') { continue }
    if ([string]$batch.status -ne 'pending') { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INVALID' 'Only pending batches may be sent.' }
    if ($MaxNewBatches -gt 0 -and $newBatchCount -ge $MaxNewBatches) {
      return [pscustomobject]@{
        ok=$true; action='Generate'; schema='super-brain.objective-answer-generator-result.v1'; status='checkpointed_partial'
        checkpointPath=$checkpointPath; checkpointSha256=(Get-ObjectiveFileSha256 $checkpointPath 'OBJECTIVE_CHECKPOINT_HASH_FAILED')
        completedCaseCount=@($checkpoint.completedAnswers).Count; completedBatchCount=@($checkpoint.batches | Where-Object { [string]$_.status -eq 'complete' }).Count
        remainingBatchCount=@($checkpoint.batches | Where-Object { [string]$_.status -eq 'pending' }).Count; resumed=[bool]$Resume
        credentialStored=$false; rawResponseStored=$false
      }
    }
    $offset = $batchIndex * $BatchSize
    $last = [Math]::Min($offset + $BatchSize - 1, $orderedCases.Count - 1)
    $batchCases = @($orderedCases[$offset..$last])
    $batch.status = 'in_progress'
    $batch.attemptCount = 1
    $batch.startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $checkpoint.status = 'active'
    Write-ObjectiveGenerationCheckpoint $checkpointPath $checkpoint
    try {
      $result = Invoke-SuperBrainResponsesRequest -Uri $connection.uri -ApiKey $connection.apiKey -Model $Model -ReasoningEffort $ReasoningEffort -RequestInput (Get-ObjectiveAnswerBatchPrompt $batchCases) -JsonSchema (Get-ObjectiveAnswerSchema $batchCases) -MaxOutputTokens $MaxOutputTokens -TimeoutSeconds $TimeoutSeconds
      $batchAnswers = @(ConvertFrom-ObjectiveAnswerBatch (Get-SuperBrainResponsesText $result.response) $batchCases $result.reportedModel)
      if ($batchAnswers.Count -ne $batchCases.Count) { Throw-ObjectiveGeneratorError 'OBJECTIVE_RESPONSE_INVALID' 'Answer generator did not produce a valid batch response.' }
      $responseId = Get-SuperBrainResponsesId $result.response
      $batchIds = @($batchAnswers | Sort-Object id | ForEach-Object { [string]$_.id }) -join ','
      $batch.responseReceiptSha256 = Get-SuperBrainTextSha256 ($batchIds + "`n1`n" + $responseId + "`n" + $result.reportedModel)
      $batch.responseModel = $result.reportedModel
      $batch.status = 'complete'
      $batch.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
      $completed = New-Object Collections.ArrayList
      foreach ($existing in @($checkpoint.completedAnswers)) { [void]$completed.Add($existing) }
      foreach ($answerCase in $batchAnswers) {
        [void]$completed.Add([pscustomobject]@{ id=[string]$answerCase.id; answer=[string]$answerCase.answer; responseModel=[string]$answerCase.responseModel })
      }
      $checkpoint.completedAnswers = @($completed)
      Write-ObjectiveGenerationCheckpoint $checkpointPath $checkpoint
      $newBatchCount++
    } catch {
      $parts = $_.Exception.Message -split '\|', 2
      $batch.status = 'blocked'
      $batch.errorCode = if ($parts.Count -eq 2) { [string]$parts[0] } else { 'OBJECTIVE_BATCH_FAILED' }
      $batch.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
      $checkpoint.status = 'blocked'
      Write-ObjectiveGenerationCheckpoint $checkpointPath $checkpoint
      throw
    }
  }
  if (@($checkpoint.batches | Where-Object { [string]$_.status -ne 'complete' }).Count -gt 0) { Throw-ObjectiveGeneratorError 'OBJECTIVE_CHECKPOINT_INCOMPLETE' 'Checkpoint did not complete every batch.' }
  $checkpoint.status = 'complete'
  Write-ObjectiveGenerationCheckpoint $checkpointPath $checkpoint
  $answerCases = Get-ObjectiveAnswerCasesFromCheckpoint $preflight $checkpoint
  $receiptParts = @($checkpoint.batches | Sort-Object index | ForEach-Object { ([string]$_.index) + "`n" + ([string]$_.caseSetSha256) + "`n" + ([string]$_.responseReceiptSha256) })
  $responseReceipt = Get-SuperBrainTextSha256 ($preflight.inputSha256 + "`n" + $metadata.endpointHash + "`n" + ($receiptParts -join "`n"))
  $totalAttempts = @($checkpoint.batches | Measure-Object -Property attemptCount -Sum).Sum
  $artifact = [pscustomobject]@{
    schema = 'super-brain.objective-answer-artifact.v1'
    status = 'answers_complete_private'
    createdAt = (Get-Date).ToString('o')
    caseSetHash = $preflight.caseSetHash
    generator = [pscustomobject]@{
      generatorId = 'super-brain.objective-answer-artifact-generator'
      generatorSha256 = $metadata.scriptHash
      runId = 'objective-generation-' + $responseReceipt.Substring(0, 32)
      executionId = [guid]::NewGuid().ToString('N')
      modelId = $Model
      modelVersion = $Model
      requestedModelId = $Model
      reportedModelId = $Model
      benchmarkVariant = 's_cleaned'
      responseCount = @($answerCases).Count
      responseModelEvidenceSha256 = Get-ObjectiveResponseModelEvidenceHash @($answerCases)
      toolchainHash = $metadata.toolchainHash
      budgetHash = $metadata.budgetHash
      environmentHash = $metadata.environmentHash
      promptTemplateHash = $metadata.promptTemplateHash
      packageVersion = [string]$metadata.manifest.version
      subjectHash = $metadata.subjectHash
      packageManifestSha256 = $metadata.manifestHash
      brainCoreSha256 = $metadata.brainCoreHash
      memoryPolicySha256 = $metadata.memoryPolicyHash
      corpusHash = $preflight.benchmark.corpusSha256
      harnessHash = $preflight.benchmark.harnessSha256
      selectionSha256 = $preflight.benchmark.selectionSha256
      pairContractSha256 = $preflight.pairContract.sha256
      configFingerprint = $metadata.configFingerprint
      independentExecution = $true
      superMemoryBrainEnabled = $preflight.superMemoryBrainEnabled
      inputSha256 = $preflight.inputSha256
      endpointSha256 = $metadata.endpointHash
      responseReceiptSha256 = $responseReceipt
      responseAttemptCount = $totalAttempts
      transportProbeReceiptSha256 = $metadata.transportProbeReceiptSha256
      rawResponseStored = $false
      referenceOrRubricSentToModel = $false
    }
    cases = @($answerCases | Sort-Object id)
    safety = [pscustomobject]@{
      diagnosticOnly = $true
      officialScore = $false
      rawAnswerStorage = 'private_artifact_only'
      credentialStored = $false
      rawResponseStored = $false
    }
  }
  Write-ObjectiveGeneratorJsonAtomic $output $artifact
  return [pscustomobject]@{
    ok = $true
    action = 'Generate'
    schema = 'super-brain.objective-answer-generator-result.v1'
    status = 'generated_private_artifact'
    outputPath = $output
    outputSha256 = Get-ObjectiveFileSha256 $output 'OBJECTIVE_OUTPUT_HASH_FAILED'
    checkpointPath = $checkpointPath
    checkpointSha256 = Get-ObjectiveFileSha256 $checkpointPath 'OBJECTIVE_CHECKPOINT_HASH_FAILED'
    inputSha256 = $preflight.inputSha256
    caseSetHash = $preflight.caseSetHash
    pairContractSha256 = $preflight.pairContract.sha256
    caseCount = @($answerCases).Count
    batchCount = @($checkpoint.batches).Count
    resumed = [bool]$Resume
    superMemoryBrainEnabled = $preflight.superMemoryBrainEnabled
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

function Write-ObjectiveGeneratorResult($Value, [int]$ExitCode = 0) {
  if ($Json) { $Value | ConvertTo-Json -Depth 24 }
  elseif ($Value.ok -eq $true) { Write-Host "OBJECTIVE_ANSWER_GENERATOR action=$Action status=$($Value.status)" }
  else { Write-Host "OBJECTIVE_ANSWER_GENERATOR_FAILED code=$($Value.code)" }
  exit $ExitCode
}

try {
  $result = switch ($Action) {
    'Status' { Get-ObjectiveGeneratorStatus }
    'Preflight' {
      $preflight = Get-ObjectiveAnswerInput $AnswerInputPath
      [pscustomobject]@{ ok=$true; action='Preflight'; schema='super-brain.objective-answer-generator-preflight.v1'; status='preflight_ok'; inputSha256=$preflight.inputSha256; caseSetHash=$preflight.caseSetHash; caseCount=$preflight.cases.Count; benchmarkVariant=$preflight.benchmark.variant; pairContractSha256=$preflight.pairContract.sha256; generationBudget=$preflight.pairContract.generationBudget; superMemoryBrainEnabled=$preflight.superMemoryBrainEnabled; privateArtifact=$true; rawReferenceSentToModel=$false }
    }
    'Probe' { Invoke-ObjectiveGeneratorProbe }
    'ExportNative' { Export-ObjectiveNativeBatches }
    'ImportNative' { Import-ObjectiveNativeBatches }
    'Generate' { Invoke-ObjectiveAnswerArtifactGeneration }
  }
  Write-ObjectiveGeneratorResult $result 0
} catch {
  $parts = $_.Exception.Message -split '\|', 2
  $code = if ($parts.Count -eq 2) { $parts[0] } else { 'OBJECTIVE_ANSWER_GENERATOR_ERROR' }
  $message = if ($parts.Count -eq 2) { $parts[1] } else { [string]$_.Exception.Message }
  Write-ObjectiveGeneratorResult ([pscustomobject]@{ ok=$false; action=$Action; schema='super-brain.objective-answer-generator-error.v1'; code=$code; error=$message; credentialStored=$false; rawResponseStored=$false }) 1
}
