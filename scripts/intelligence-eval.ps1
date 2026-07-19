param(
  [ValidateSet('Binding','Seal','Evaluate')]
  [string]$Action = 'Evaluate',
  [string]$HoldoutPath = '',
  [string]$OutputPath = '',
  [string]$EvidencePath = '',
  [string]$PolicyPath = '',
  [string]$ReportPath = '',
  [string]$ConsumedMarkerPath = '',
  [string]$AutonomyWorkspaceRoot = '',
  [string]$WorkspaceKey = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $Default }
  return $Object.PSObject.Properties[$Name].Value
}

function ConvertTo-CanonicalNode($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or $Value -is [datetime] -or $Value.GetType().IsPrimitive -or $Value -is [decimal]) { return $Value }
  if ($Value -is [Collections.IDictionary]) {
    $ordered = [ordered]@{}
    foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) { $ordered[$key] = ConvertTo-CanonicalNode $Value[$key] }
    return [pscustomobject]$ordered
  }
  if ($Value -is [pscustomobject]) {
    $ordered = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) { $ordered[$property.Name] = ConvertTo-CanonicalNode $property.Value }
    return [pscustomobject]$ordered
  }
  if ($Value -is [Collections.IEnumerable]) {
    $items = New-Object Collections.ArrayList
    foreach ($item in $Value) { [void]$items.Add((ConvertTo-CanonicalNode $item)) }
    $array = $items.ToArray()
    return ,$array
  }
  return [string]$Value
}

function Get-ObjectSha256($Value) {
  $canonical = ConvertTo-CanonicalNode $Value
  $text = $canonical | ConvertTo-Json -Depth 100 -Compress
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }))
  } finally { $sha.Dispose() }
}

function Get-FileSha256([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Throw-EvalError 'EVIDENCE_BINDING_RUNTIME_MISSING' "Runtime source is missing: $Path"
  }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
  catch { Throw-EvalError 'EVIDENCE_BINDING_RUNTIME_UNREADABLE' "Runtime source cannot be hashed: $Path" }
}

function Get-CurrentEvidenceBinding($Manifest) {
  $runtimeFiles = @($Manifest.nativeRuntimeFiles)
  if ($runtimeFiles.Count -lt 1) { Throw-EvalError 'EVIDENCE_BINDING_RUNTIME_LIST_MISSING' 'Manifest has no native runtime files.' }
  $behaviorFiles = @($Manifest.intelligenceBehaviorFiles)
  if ($behaviorFiles.Count -lt 1) { Throw-EvalError 'EVIDENCE_BINDING_BEHAVIOR_LIST_MISSING' 'Manifest has no intelligence behavior files.' }
  $runtimeHashes = New-Object Collections.ArrayList
  foreach ($relativePath in $runtimeFiles) {
    $relative = [string]$relativePath
    if ([string]::IsNullOrWhiteSpace($relative)) { Throw-EvalError 'EVIDENCE_BINDING_RUNTIME_LIST_INVALID' 'Manifest contains an empty native runtime path.' }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $relative))
    $rootPrefix = $Root.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { Throw-EvalError 'EVIDENCE_BINDING_RUNTIME_PATH_ESCAPE' "Native runtime path escapes package root: $relative" }
    [void]$runtimeHashes.Add([pscustomobject]@{ path=$relative; sha256=(Get-FileSha256 $fullPath) })
  }
  $behaviorHashes = New-Object Collections.ArrayList
  foreach ($relativePath in $behaviorFiles) {
    $relative = [string]$relativePath
    if ([string]::IsNullOrWhiteSpace($relative)) { Throw-EvalError 'EVIDENCE_BINDING_BEHAVIOR_LIST_INVALID' 'Manifest contains an empty intelligence behavior path.' }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $relative))
    $rootPrefix = $Root.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { Throw-EvalError 'EVIDENCE_BINDING_BEHAVIOR_PATH_ESCAPE' "Intelligence behavior path escapes package root: $relative" }
    [void]$behaviorHashes.Add([pscustomobject]@{ path=$relative; sha256=(Get-FileSha256 $fullPath) })
  }
  $manifestPath = Join-Path $Root 'manifest.json'
  return [pscustomobject]@{
    schema = 'super-brain.intelligence-evidence-binding.v2'
    packageVersion = [string]$Manifest.version
    manifestSha256 = Get-FileSha256 $manifestPath
    runtimeSourceSha256 = Get-ObjectSha256 @($runtimeHashes)
    runtimeFiles = @($runtimeHashes)
    behaviorSourceSha256 = Get-ObjectSha256 @($behaviorHashes)
    behaviorFiles = @($behaviorHashes)
  }
}

function Get-EvidenceFreshness($Evidence, $Policy) {
  $freshnessPolicy = Get-PropertyValue $Policy 'evidenceFreshness' ([pscustomobject]@{})
  $maxAgeHours = [double](Get-PropertyValue $freshnessPolicy 'maxAgeHours' 72)
  $maxFutureSkewMinutes = [double](Get-PropertyValue $freshnessPolicy 'maxFutureSkewMinutes' 5)
  if ($maxAgeHours -le 0 -or $maxFutureSkewMinutes -lt 0) { Throw-EvalError 'EVIDENCE_FRESHNESS_POLICY_INVALID' 'Evidence freshness policy is invalid.' }
  $generatedAtText = [string](Get-PropertyValue $Evidence 'generatedAt' '')
  if ([string]::IsNullOrWhiteSpace($generatedAtText)) { Throw-EvalError 'EVIDENCE_GENERATED_AT_MISSING' 'Evidence generatedAt is required.' }
  try { $generatedAt = [DateTimeOffset]::Parse($generatedAtText) }
  catch { Throw-EvalError 'EVIDENCE_GENERATED_AT_INVALID' 'Evidence generatedAt is not a valid timestamp.' }
  $ageHours = ([DateTimeOffset]::UtcNow - $generatedAt.ToUniversalTime()).TotalHours
  if ($ageHours -lt (-1.0 * $maxFutureSkewMinutes / 60.0)) { Throw-EvalError 'EVIDENCE_GENERATED_AT_FUTURE' 'Evidence generatedAt is too far in the future.' }
  if ($ageHours -gt $maxAgeHours) { Throw-EvalError 'EVIDENCE_STALE' "Evidence is older than $maxAgeHours hours." }
  return [pscustomobject]@{
    fresh = $true
    generatedAt = $generatedAt.ToString('o')
    ageHours = [Math]::Round([Math]::Max(0.0, $ageHours), 4)
    maxAgeHours = $maxAgeHours
    maxFutureSkewMinutes = $maxFutureSkewMinutes
  }
}

function Assert-EvidenceBinding($Evidence, $CurrentBinding) {
  $binding = Get-PropertyValue $Evidence 'evidenceBinding' $null
  if ($null -eq $binding) { Throw-EvalError 'EVIDENCE_BINDING_MISSING' 'Evidence binding is required.' }
  if ([string]$binding.schema -ne [string]$CurrentBinding.schema) { Throw-EvalError 'EVIDENCE_BINDING_SCHEMA_INVALID' 'Evidence binding schema is unsupported.' }
  if ([string]$binding.packageVersion -ne [string]$CurrentBinding.packageVersion) { Throw-EvalError 'EVIDENCE_PACKAGE_VERSION_MISMATCH' 'Evidence package version does not match the current package.' }
  if ([string]$binding.manifestSha256 -ne [string]$CurrentBinding.manifestSha256) { Throw-EvalError 'EVIDENCE_MANIFEST_HASH_MISMATCH' 'Evidence manifest hash does not match the current package.' }
  if ([string]$binding.runtimeSourceSha256 -ne [string]$CurrentBinding.runtimeSourceSha256) { Throw-EvalError 'EVIDENCE_RUNTIME_HASH_MISMATCH' 'Evidence runtime source hash does not match the current package.' }
  $recordedFiles = @($binding.runtimeFiles)
  $currentFiles = @($CurrentBinding.runtimeFiles)
  if ($recordedFiles.Count -ne $currentFiles.Count) { Throw-EvalError 'EVIDENCE_RUNTIME_FILE_SET_MISMATCH' 'Evidence runtime file set does not match the current package.' }
  foreach ($currentFile in $currentFiles) {
    $recorded = @($recordedFiles | Where-Object { [string]$_.path -eq [string]$currentFile.path })
    if ($recorded.Count -ne 1 -or [string]$recorded[0].sha256 -ne [string]$currentFile.sha256) { Throw-EvalError 'EVIDENCE_RUNTIME_HASH_MISMATCH' "Evidence runtime source hash does not match: $($currentFile.path)" }
  }
  if ([string]$binding.behaviorSourceSha256 -ne [string]$CurrentBinding.behaviorSourceSha256) { Throw-EvalError 'EVIDENCE_BEHAVIOR_HASH_MISMATCH' 'Evidence behavior source hash does not match the current package.' }
  $recordedBehaviorFiles = @($binding.behaviorFiles)
  $currentBehaviorFiles = @($CurrentBinding.behaviorFiles)
  if ($recordedBehaviorFiles.Count -ne $currentBehaviorFiles.Count) { Throw-EvalError 'EVIDENCE_BEHAVIOR_FILE_SET_MISMATCH' 'Evidence behavior source file set does not match the current package.' }
  foreach ($currentFile in $currentBehaviorFiles) {
    $recorded = @($recordedBehaviorFiles | Where-Object { [string]$_.path -eq [string]$currentFile.path })
    if ($recorded.Count -ne 1 -or [string]$recorded[0].sha256 -ne [string]$currentFile.sha256) { Throw-EvalError 'EVIDENCE_BEHAVIOR_HASH_MISMATCH' "Evidence behavior source hash does not match: $($currentFile.path)" }
  }
  return $CurrentBinding
}

function Throw-EvalError([string]$Code, [string]$Message) {
  throw [InvalidOperationException]::new("$Code|$Message")
}

function Read-JsonFile([string]$Path, [string]$Code) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { Throw-EvalError $Code 'Required JSON file is missing.' }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Throw-EvalError $Code 'JSON is invalid.' }
}

function Get-AutonomyEvidenceLedger([string]$StateWorkspaceRoot, [string]$Key) {
  $ledgerScript = Join-Path $PSScriptRoot 'autonomy-evidence-ledger.ps1'
  if (-not (Test-Path -LiteralPath $ledgerScript -PathType Leaf)) { Throw-EvalError 'AUTONOMY_LEDGER_MISSING' 'Autonomy evidence ledger runtime is missing.' }
  $ledgerArgs = @('-Action','Audit','-Json')
  if (-not [string]::IsNullOrWhiteSpace($StateWorkspaceRoot)) { $ledgerArgs += @('-WorkspaceRoot',[IO.Path]::GetFullPath($StateWorkspaceRoot)) }
  if (-not [string]::IsNullOrWhiteSpace($Key)) { $ledgerArgs += @('-WorkspaceKey',$Key) }
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ledgerScript @ledgerArgs 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) { Throw-EvalError 'AUTONOMY_LEDGER_UNAVAILABLE' 'Autonomy evidence ledger did not return a valid result.' }
  try { $ledger = $text | ConvertFrom-Json } catch { Throw-EvalError 'AUTONOMY_LEDGER_INVALID' 'Autonomy evidence ledger returned invalid JSON.' }
  if ($ledger.ok -ne $true -or [string]$ledger.schema -ne 'super-brain.autonomy-evidence-ledger.v1' -or -not $ledger.evidenceCounts) { Throw-EvalError 'AUTONOMY_LEDGER_INVALID' 'Autonomy evidence ledger failed its schema or evidence contract.' }
  return $ledger
}

function Test-BooleanProperty($Object, [string]$Name) {
  return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $Object.PSObject.Properties[$Name].Value -is [bool])
}

function Get-EvidenceRefCount($Object) {
  $refs = @(Get-PropertyValue $Object 'evidenceRefs' @() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  return $refs.Count
}

function Get-PassSummary([object[]]$Cases, [switch]$RequireHash) {
  $passed = 0
  $evidenced = 0
  foreach ($case in @($Cases)) {
    if (-not (Test-BooleanProperty $case 'passed')) { Throw-EvalError 'RESULT_SCHEMA_INVALID' 'Every result needs a Boolean passed field.' }
    if ($RequireHash -and [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $case 'caseHash' ''))) { Throw-EvalError 'RESULT_SCHEMA_INVALID' 'Every holdout result needs a caseHash.' }
    if ([bool]$case.passed) { $passed++ }
    if ((Get-EvidenceRefCount $case) -gt 0) { $evidenced++ }
  }
  $count = @($Cases).Count
  return [pscustomobject]@{
    count = $count
    passed = $passed
    passRate = if ($count -gt 0) { [Math]::Round($passed / $count, 6) } else { $null }
    evidenceComplete = ($count -gt 0 -and $evidenced -eq $count)
    evidencedCount = $evidenced
  }
}

function Get-SealedSetHash($Sealed) {
  $descriptors = @($Sealed.cases | ForEach-Object { [pscustomobject]@{ id=[string]$_.id; caseHash=[string]$_.caseHash } })
  return Get-ObjectSha256 ([pscustomobject]@{ schema=[string]$Sealed.schema; setId=[string]$Sealed.setId; caseCount=$descriptors.Count; cases=$descriptors })
}

function Assert-SealedHoldout($Sealed) {
  if ([string]$Sealed.schema -ne 'super-brain.intelligence-holdout.sealed.v1') { Throw-EvalError 'HOLDOUT_SCHEMA_INVALID' 'The holdout is not a sealed v1 set.' }
  $cases = @($Sealed.cases)
  if ($cases.Count -lt 1 -or [int]$Sealed.caseCount -ne $cases.Count) { Throw-EvalError 'HOLDOUT_SCHEMA_INVALID' 'Sealed case count is invalid.' }
  $ids = @{}
  foreach ($case in $cases) {
    $id = [string]$case.id
    if ([string]::IsNullOrWhiteSpace($id) -or $ids.ContainsKey($id)) { Throw-EvalError 'HOLDOUT_SCHEMA_INVALID' 'Case IDs must be non-empty and unique.' }
    $ids[$id] = $true
    $actualHash = Get-ObjectSha256 $case.payload
    if ($actualHash -ne [string]$case.caseHash) { Throw-EvalError 'HOLDOUT_CASE_HASH_MISMATCH' 'A sealed holdout case was modified.' }
  }
  $setHash = Get-SealedSetHash $Sealed
  if ($setHash -ne [string]$Sealed.setHash) { Throw-EvalError 'HOLDOUT_SET_HASH_MISMATCH' 'The sealed holdout index was modified.' }
  return $setHash
}

function New-Gate([string]$Id, [bool]$Met, $Observed, $Required) {
  return [pscustomobject]@{ id=$Id; met=$Met; observed=$Observed; required=$Required }
}

function Get-WeightedScore($Weights, $Dimensions) {
  $score = 0.0
  foreach ($weight in $Weights.PSObject.Properties) {
    $dimension = $Dimensions.PSObject.Properties[$weight.Name].Value
    $score += ([double]$weight.Value * [double]$dimension.score)
  }
  return [Math]::Round($score, 6)
}

function Get-WeightSum($Weights) {
  $sum = 0.0
  foreach ($weight in $Weights.PSObject.Properties) { $sum += [double]$weight.Value }
  return [Math]::Round($sum, 8)
}

function Write-OutputObject($Value, [int]$ExitCode) {
  if ($Json) { $Value | ConvertTo-Json -Depth 20 }
  elseif ($Value.ok -eq $true) {
    if ($Action -eq 'Binding') { Write-Host "INTELLIGENCE_EVIDENCE_BINDING version=$($Value.binding.packageVersion) manifest=$($Value.binding.manifestSha256) runtime=$($Value.binding.runtimeSourceSha256)" }
    elseif ($Action -eq 'Seal') { Write-Host "INTELLIGENCE_HOLDOUT_SEALED cases=$($Value.caseCount) hash=$($Value.setHash)" }
    else { Write-Host "INTELLIGENCE_EVAL personal=$($Value.scores.personalControlPlane.final) autonomous=$($Value.scores.autonomousBrain.final) gap=$($Value.antiOverfitting.gap)" }
  } else { Write-Host "INTELLIGENCE_EVAL_FAILED code=$($Value.code) error=$($Value.error)" }
  exit $ExitCode
}

try {
  if ([string]::IsNullOrWhiteSpace($PolicyPath)) { $PolicyPath = Join-Path $Root 'intelligence-policy.json' }
  $PolicyPath = [IO.Path]::GetFullPath($PolicyPath)
  $policy = Read-JsonFile $PolicyPath 'POLICY_MISSING_OR_INVALID'
  if ([string]$policy.schema -ne 'super-brain.intelligence-policy.v1') { Throw-EvalError 'POLICY_SCHEMA_INVALID' 'Unsupported intelligence policy schema.' }
  $manifest = Read-JsonFile (Join-Path $Root 'manifest.json') 'MANIFEST_MISSING_OR_INVALID'
  $currentBinding = Get-CurrentEvidenceBinding $manifest
  $personalWeightSum = Get-WeightSum $policy.weights.personalControlPlane
  $autonomousWeightSum = Get-WeightSum $policy.weights.autonomousBrain
  if ([Math]::Abs($personalWeightSum-1.0) -gt 0.000001 -or [Math]::Abs($autonomousWeightSum-1.0) -gt 0.000001) { Throw-EvalError 'POLICY_WEIGHT_SUM_INVALID' 'Every target weight set must sum to 1.0.' }

  if ($Action -eq 'Binding') {
    Write-OutputObject ([pscustomobject]@{ ok=$true; action='Binding'; schema=$currentBinding.schema; binding=$currentBinding }) 0
  }

  if ($Action -eq 'Seal') {
    $source = Read-JsonFile ([IO.Path]::GetFullPath($HoldoutPath)) 'HOLDOUT_SOURCE_MISSING_OR_INVALID'
    $sourceCases = @($source.cases)
    if ($sourceCases.Count -lt 1) { Throw-EvalError 'HOLDOUT_SOURCE_EMPTY' 'At least one holdout case is required.' }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { Throw-EvalError 'OUTPUT_PATH_REQUIRED' 'Seal requires OutputPath.' }
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $OutputPath) { Throw-EvalError 'SEALED_OUTPUT_EXISTS' 'Refusing to overwrite an existing sealed holdout.' }
    $setId = [string](Get-PropertyValue $source 'setId' '')
    if ([string]::IsNullOrWhiteSpace($setId)) { Throw-EvalError 'HOLDOUT_SET_ID_REQUIRED' 'A stable setId is required.' }
    $ids = @{}
    $sealedCases = New-Object Collections.ArrayList
    foreach ($case in $sourceCases) {
      $id = [string](Get-PropertyValue $case 'id' '')
      if ([string]::IsNullOrWhiteSpace($id) -or $ids.ContainsKey($id)) { Throw-EvalError 'HOLDOUT_CASE_ID_INVALID' 'Case IDs must be non-empty and unique.' }
      $ids[$id] = $true
      [void]$sealedCases.Add([pscustomobject]@{ id=$id; caseHash=(Get-ObjectSha256 $case); payload=$case })
    }
    $sealed = [pscustomobject]@{
      schema = 'super-brain.intelligence-holdout.sealed.v1'
      setId = $setId
      sealedAt = (Get-Date).ToString('o')
      caseCount = $sealedCases.Count
      cases = @($sealedCases)
      setHash = ''
    }
    $sealed.setHash = Get-SealedSetHash $sealed
    Write-JsonUtf8NoBom $OutputPath $sealed 100
    $sealResult = [pscustomobject]@{ ok=$true; action='Seal'; schema=$sealed.schema; caseCount=$sealed.caseCount; setHash=$sealed.setHash; rawPromptsInResult=$false; outputPath=$OutputPath }
    Write-OutputObject $sealResult 0
  }

  $evidence = Read-JsonFile ([IO.Path]::GetFullPath($EvidencePath)) 'EVIDENCE_MISSING_OR_INVALID'
  if ([string]$evidence.schema -notin @('super-brain.intelligence-evidence.v1','super-brain.intelligence-evidence.v2')) { Throw-EvalError 'EVIDENCE_SCHEMA_INVALID' 'Unsupported intelligence evidence schema.' }
  $evidenceFreshness = Get-EvidenceFreshness $evidence $policy
  [void](Assert-EvidenceBinding $evidence $currentBinding)
  $calibrationCases = @(Get-PropertyValue $evidence 'calibrationCases' @())
  $calibration = Get-PassSummary $calibrationCases
  $callerCounts = Get-PropertyValue $evidence 'evidenceCounts' ([pscustomobject]@{})
  $ledger = Get-AutonomyEvidenceLedger $AutonomyWorkspaceRoot $WorkspaceKey
  $ledgerCounts = $ledger.evidenceCounts
  $verifiedTasks = [Math]::Max(0, [int](Get-PropertyValue $ledgerCounts 'verifiedRealWorldTasks' 0))
  $autonomyScenarios = [Math]::Max(0, [int](Get-PropertyValue $ledgerCounts 'verifiedAutonomyScenarios' 0))
  $closedCorrections = [Math]::Max(0, [int](Get-PropertyValue $ledgerCounts 'closedCorrectionLoops' 0))
  $callerSuppliedCountsIgnored = ($null -ne $callerCounts)

  $hasHoldout = -not [string]::IsNullOrWhiteSpace($HoldoutPath)
  $holdout = [pscustomobject]@{ present=$false; verified=$false; caseCount=0; passed=0; passRate=$null; evidenceComplete=$false; setHash=''; consumed=$false; caseResults=@() }
  if ($hasHoldout) {
    $HoldoutPath = [IO.Path]::GetFullPath($HoldoutPath)
    $sealed = Read-JsonFile $HoldoutPath 'HOLDOUT_MISSING_OR_INVALID'
    $setHash = Assert-SealedHoldout $sealed
    if ([string]::IsNullOrWhiteSpace($ConsumedMarkerPath)) { $ConsumedMarkerPath = "$HoldoutPath.consumed.json" }
    $ConsumedMarkerPath = [IO.Path]::GetFullPath($ConsumedMarkerPath)
    if (Test-Path -LiteralPath $ConsumedMarkerPath) { Throw-EvalError 'HOLDOUT_ALREADY_CONSUMED' 'This sealed holdout already has a consumption marker.' }
    $results = @(Get-PropertyValue $evidence 'holdoutResults' @())
    if ($results.Count -ne @($sealed.cases).Count) { Throw-EvalError 'HOLDOUT_RESULT_COUNT_MISMATCH' 'Results must cover every sealed case exactly once.' }
    $resultMap = @{}
    foreach ($result in $results) {
      $id = [string](Get-PropertyValue $result 'id' '')
      if ([string]::IsNullOrWhiteSpace($id) -or $resultMap.ContainsKey($id)) { Throw-EvalError 'HOLDOUT_RESULT_ID_INVALID' 'Result IDs must be non-empty and unique.' }
      $resultMap[$id] = $result
    }
    $orderedResults = New-Object Collections.ArrayList
    foreach ($case in @($sealed.cases)) {
      if (-not $resultMap.ContainsKey([string]$case.id)) { Throw-EvalError 'HOLDOUT_RESULT_MISSING' 'A sealed case has no result.' }
      $result = $resultMap[[string]$case.id]
      if ([string]$result.caseHash -ne [string]$case.caseHash) { Throw-EvalError 'HOLDOUT_RESULT_HASH_MISMATCH' 'A result does not match its sealed case hash.' }
      [void]$orderedResults.Add($result)
    }
    $summary = Get-PassSummary @($orderedResults) -RequireHash
    $sanitized = @($orderedResults | ForEach-Object { [pscustomobject]@{ caseHash=[string]$_.caseHash; passed=[bool]$_.passed; evidenceRefCount=(Get-EvidenceRefCount $_) } })
    $holdout = [pscustomobject]@{ present=$true; verified=$true; caseCount=$summary.count; passed=$summary.passed; passRate=$summary.passRate; evidenceComplete=$summary.evidenceComplete; setHash=$setHash; consumed=$false; caseResults=$sanitized }
  }

  $dimensionInput = Get-PropertyValue $evidence 'dimensions' ([pscustomobject]@{})
  $dimensionNames = @($policy.weights.personalControlPlane.PSObject.Properties.Name + $policy.weights.autonomousBrain.PSObject.Properties.Name | Select-Object -Unique)
  $dimensionsMap = [ordered]@{}
  $dimensionEvidenceComplete = $true
  $minimumSamples = [int]$policy.dimensionEvidence.minimumSampleCount
  foreach ($name in $dimensionNames) {
    if ($name -eq 'autonomyEvidence') {
      $rates = @(
        [Math]::Min($verifiedTasks / [double]$policy.autonomyEvidence.minimumVerifiedRealWorldTasks, 1.0),
        [Math]::Min($autonomyScenarios / [double]$policy.autonomyEvidence.minimumVerifiedAutonomyScenarios, 1.0),
        [Math]::Min($closedCorrections / [double]$policy.autonomyEvidence.minimumClosedCorrectionLoops, 1.0)
      )
      $rate = [Math]::Round((($rates | Measure-Object -Average).Average), 6)
      $dimensionsMap[$name] = [pscustomobject]@{ rate=$rate; score=[Math]::Round($rate*10,4); sampleCount=($verifiedTasks+$autonomyScenarios+$closedCorrections); evidenceRefCount=3; source='derived_autonomy_evidence_ledger'; valid=$true }
      continue
    }
    if ($name -eq 'generalization' -and $holdout.present) {
      $valid = ($holdout.evidenceComplete -and $holdout.caseCount -ge $minimumSamples)
      if (-not $valid) { $dimensionEvidenceComplete = $false }
      $dimensionsMap[$name] = [pscustomobject]@{ rate=[double]$holdout.passRate; score=[Math]::Round(([double]$holdout.passRate*10),4); sampleCount=$holdout.caseCount; evidenceRefCount=$holdout.caseCount; source='sealed_holdout'; valid=$valid }
      continue
    }
    $entryProperty = $dimensionInput.PSObject.Properties[$name]
    $entry = if ($null -ne $entryProperty) { $entryProperty.Value } else { $null }
    $rate = if ($entry -and $null -ne $entry.PSObject.Properties['rate']) { [double]$entry.rate } else { 0.0 }
    $sampleCount = if ($entry -and $null -ne $entry.PSObject.Properties['sampleCount']) { [int]$entry.sampleCount } else { 0 }
    $refCount = if ($entry) { Get-EvidenceRefCount $entry } else { 0 }
    $valid = ($null -ne $entry -and $rate -ge 0.0 -and $rate -le 1.0 -and $sampleCount -ge $minimumSamples -and $refCount -gt 0)
    if (-not $valid) { $dimensionEvidenceComplete = $false; $rate = [Math]::Max(0.0,[Math]::Min($rate,1.0)) }
    $dimensionsMap[$name] = [pscustomobject]@{ rate=[Math]::Round($rate,6); score=[Math]::Round($rate*10,4); sampleCount=$sampleCount; evidenceRefCount=$refCount; source='external_measurement'; valid=$valid }
  }
  $dimensions = [pscustomobject]$dimensionsMap

  $gap = if ($holdout.present -and $null -ne $calibration.passRate) { [Math]::Round([Math]::Max(0.0, [double]$calibration.passRate - [double]$holdout.passRate), 6) } else { $null }
  $penalty = if ($null -ne $gap) { [Math]::Round([double]$gap * [double]$policy.antiOverfitting.gapPenaltyScale, 4) } else { 0.0 }
  $personalRaw = Get-WeightedScore $policy.weights.personalControlPlane $dimensions
  $autonomousRaw = Get-WeightedScore $policy.weights.autonomousBrain $dimensions
  $personalCeiling = 10.0
  $autonomousCeiling = 10.0
  $personalCeilingReasons = New-Object Collections.ArrayList
  $autonomousCeilingReasons = New-Object Collections.ArrayList
  if (-not $holdout.present) {
    $personalCeiling = [double]$policy.antiOverfitting.noHoldoutPersonalCeiling
    $autonomousCeiling = [double]$policy.antiOverfitting.noHoldoutAutonomousCeiling
    [void]$personalCeilingReasons.Add('no_sealed_holdout')
    [void]$autonomousCeilingReasons.Add('no_sealed_holdout')
  }
  $autonomyCountsComplete = ($verifiedTasks -ge [int]$policy.autonomyEvidence.minimumVerifiedRealWorldTasks -and $autonomyScenarios -ge [int]$policy.autonomyEvidence.minimumVerifiedAutonomyScenarios -and $closedCorrections -ge [int]$policy.autonomyEvidence.minimumClosedCorrectionLoops)
  if (-not $autonomyCountsComplete) {
    $autonomousCeiling = [Math]::Min($autonomousCeiling, [double]$policy.autonomyEvidence.insufficientEvidenceCeiling)
    [void]$autonomousCeilingReasons.Add('insufficient_autonomy_evidence')
  }
  $personalFinal = [Math]::Round([Math]::Min([Math]::Max(0.0,$personalRaw-$penalty),$personalCeiling),2)
  $autonomousFinal = [Math]::Round([Math]::Min([Math]::Max(0.0,$autonomousRaw-$penalty),$autonomousCeiling),2)

  $personalGates = @(
    (New-Gate 'dimension_evidence_complete' $dimensionEvidenceComplete $dimensionEvidenceComplete $true),
    (New-Gate 'calibration_evidence_present' ($calibration.count -gt 0 -and $calibration.evidenceComplete) $calibration.count 'at least 1 evidenced case'),
    (New-Gate 'sealed_holdout_verified' $holdout.verified $holdout.verified $true),
    (New-Gate 'personal_holdout_case_count' ($holdout.caseCount -ge [int]$policy.antiOverfitting.personalMinimumHoldoutCases) $holdout.caseCount ([int]$policy.antiOverfitting.personalMinimumHoldoutCases)),
    (New-Gate 'personal_holdout_pass_rate' ($holdout.present -and [double]$holdout.passRate -ge [double]$policy.antiOverfitting.personalMinimumHoldoutPassRate) $holdout.passRate ([double]$policy.antiOverfitting.personalMinimumHoldoutPassRate)),
    (New-Gate 'personal_overfit_gap' ($null -ne $gap -and [double]$gap -le [double]$policy.antiOverfitting.personalMaximumGap) $gap ([double]$policy.antiOverfitting.personalMaximumGap)),
    (New-Gate 'personal_numeric_target' ($personalFinal -ge [double]$policy.targets.personalControlPlane) $personalFinal ([double]$policy.targets.personalControlPlane))
  )
  $autonomousGates = @(
    (New-Gate 'dimension_evidence_complete' $dimensionEvidenceComplete $dimensionEvidenceComplete $true),
    (New-Gate 'calibration_evidence_present' ($calibration.count -gt 0 -and $calibration.evidenceComplete) $calibration.count 'at least 1 evidenced case'),
    (New-Gate 'sealed_holdout_verified' $holdout.verified $holdout.verified $true),
    (New-Gate 'autonomous_holdout_case_count' ($holdout.caseCount -ge [int]$policy.antiOverfitting.autonomousMinimumHoldoutCases) $holdout.caseCount ([int]$policy.antiOverfitting.autonomousMinimumHoldoutCases)),
    (New-Gate 'autonomous_holdout_pass_rate' ($holdout.present -and [double]$holdout.passRate -ge [double]$policy.antiOverfitting.autonomousMinimumHoldoutPassRate) $holdout.passRate ([double]$policy.antiOverfitting.autonomousMinimumHoldoutPassRate)),
    (New-Gate 'autonomous_overfit_gap' ($null -ne $gap -and [double]$gap -le [double]$policy.antiOverfitting.autonomousMaximumGap) $gap ([double]$policy.antiOverfitting.autonomousMaximumGap)),
    (New-Gate 'verified_real_world_tasks' ($verifiedTasks -ge [int]$policy.autonomyEvidence.minimumVerifiedRealWorldTasks) $verifiedTasks ([int]$policy.autonomyEvidence.minimumVerifiedRealWorldTasks)),
    (New-Gate 'verified_autonomy_scenarios' ($autonomyScenarios -ge [int]$policy.autonomyEvidence.minimumVerifiedAutonomyScenarios) $autonomyScenarios ([int]$policy.autonomyEvidence.minimumVerifiedAutonomyScenarios)),
    (New-Gate 'closed_correction_loops' ($closedCorrections -ge [int]$policy.autonomyEvidence.minimumClosedCorrectionLoops) $closedCorrections ([int]$policy.autonomyEvidence.minimumClosedCorrectionLoops)),
    (New-Gate 'autonomous_numeric_target' ($autonomousFinal -ge [double]$policy.targets.autonomousBrain) $autonomousFinal ([double]$policy.targets.autonomousBrain))
  )

  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $workspace 'last-intelligence-eval.json' }
  $ReportPath = [IO.Path]::GetFullPath($ReportPath)
  $report = [pscustomobject]@{
    ok = $true
    action = 'Evaluate'
    schema = 'super-brain.intelligence-eval.v1'
    evaluationScope = 'internal_acceptance_only'
    objectiveIntelligenceScore = $false
    externalBenchmarkRequiredForObjectiveClaim = $true
    checkedAt = (Get-Date).ToString('o')
    evidenceGeneratedAt = $evidenceFreshness.generatedAt
    evidenceFreshness = $evidenceFreshness
    evidenceBinding = $currentBinding
    policyHash = Get-ObjectSha256 $policy
    dimensions = $dimensions
    calibration = $calibration
    holdout = $holdout
    antiOverfitting = [pscustomobject]@{ measured=($null-ne$gap); calibrationPassRate=$calibration.passRate; holdoutPassRate=$holdout.passRate; gap=$gap; penalty=$penalty; penaltyScale=[double]$policy.antiOverfitting.gapPenaltyScale; status=$(if(-not $holdout.present){'no_holdout'}elseif($null-eq$gap){'no_calibration'}elseif($gap -le [double]$policy.antiOverfitting.personalMaximumGap){'within_personal_limit'}else{'overfit_gap_detected'}) }
    evidenceCounts = [pscustomobject]@{ verifiedRealWorldTasks=$verifiedTasks; verifiedAutonomyScenarios=$autonomyScenarios; closedCorrectionLoops=$closedCorrections }
    autonomyEvidence = [pscustomobject]@{ source='autonomy-evidence-ledger.ps1'; schema=[string]$ledger.schema; checkedAt=[string]$ledger.checkedAt; workspaceKey=[string]$ledger.workspaceKey; packageVersion=[string]$ledger.packageVersion; rejectedRecordCount=[int]$ledger.records.rejectedCount; callerSuppliedCountsIgnored=$callerSuppliedCountsIgnored; genericCompletionCounts=$false }
    scores = [pscustomobject]@{
      personalControlPlane = [pscustomobject]@{ raw=[Math]::Round($personalRaw,2); overfitPenalty=$penalty; ceiling=$personalCeiling; ceilingReasons=@($personalCeilingReasons); final=$personalFinal; target=[double]$policy.targets.personalControlPlane; achieved=(@($personalGates|Where-Object{-not$_.met}).Count-eq0); unmetGates=@($personalGates|Where-Object{-not$_.met}|ForEach-Object{$_.id}); gates=$personalGates }
      autonomousBrain = [pscustomobject]@{ raw=[Math]::Round($autonomousRaw,2); overfitPenalty=$penalty; ceiling=$autonomousCeiling; ceilingReasons=@($autonomousCeilingReasons); final=$autonomousFinal; target=[double]$policy.targets.autonomousBrain; achieved=(@($autonomousGates|Where-Object{-not$_.met}).Count-eq0); unmetGates=@($autonomousGates|Where-Object{-not$_.met}|ForEach-Object{$_.id}); gates=$autonomousGates }
    }
    privacy = [pscustomobject]@{ rawHoldoutPromptsCopiedToReport=$false; casePayloadsCopiedToReport=$false; reportContainsHashesAndAggregateMetricsOnly=$true }
    claimGuard = 'These scores are package-local acceptance metrics, not an objective or externally comparable intelligence score. Use paired official benchmark results for objective claims.'
  }
  Write-JsonUtf8NoBom $ReportPath $report 30
  if ($holdout.present) {
    $report.holdout.consumed = $true
    Write-JsonUtf8NoBom $ReportPath $report 30
    $marker = [pscustomobject]@{ schema='super-brain.intelligence-holdout-consumption.v1'; setHash=$holdout.setHash; consumedAt=(Get-Date).ToString('o'); reportHash=(Get-FileHash -LiteralPath $ReportPath -Algorithm SHA256).Hash.ToLowerInvariant(); rule='Consumed holdout cannot become a tuning set; create and seal a new set after any tuning.' }
    Write-JsonUtf8NoBom $ConsumedMarkerPath $marker 8
  }
  Write-OutputObject $report 0
} catch {
  $parts = $_.Exception.Message -split '\|', 2
  $code = if ($parts.Count -eq 2) { $parts[0] } else { 'INTELLIGENCE_EVAL_ERROR' }
  $message = if ($parts.Count -eq 2) { $parts[1] } else { 'Evaluation failed.' }
  $failure = [pscustomobject]@{ ok=$false; action=$Action; schema='super-brain.intelligence-eval-error.v1'; code=$code; error=$message; rawHoldoutPromptsCopied=$false }
  Write-OutputObject $failure 1
}
