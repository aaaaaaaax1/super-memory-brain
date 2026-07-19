param(
  [string]$TestsPath = '',
  [ValidateSet('static','recall','decision','all')]
  [string]$Mode = 'all',
  [switch]$Json
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($TestsPath)) {
  $TestsPath = Join-Path $Root 'tests\memory-eval-tests.json'
}
$TestsPath = [System.IO.Path]::GetFullPath($TestsPath)
$tests = Get-Content -LiteralPath $TestsPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-ArrayProperty($Object, [string]$Name) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return @() }
  return @($Object.PSObject.Properties[$Name].Value)
}

function Get-StringProperty($Object, [string]$Name, [string]$Default = '') {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $Default }
  return [string]$Object.PSObject.Properties[$Name].Value
}

function Get-IntProperty($Object, [string]$Name, [int]$Default) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $Default }
  return [int]$Object.PSObject.Properties[$Name].Value
}

function Get-DoubleProperty($Object, [string]$Name, [double]$Default) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $Default }
  return [double]$Object.PSObject.Properties[$Name].Value
}

function Test-ModeEnabled([string]$CaseMode) {
  if ($Mode -eq 'all') { return $true }
  if ($Mode -eq 'static' -and $CaseMode -eq 'staticSources') { return $true }
  if ($Mode -eq 'recall' -and $CaseMode -eq 'recallSearch') { return $true }
  if ($Mode -eq 'decision' -and $CaseMode -eq 'decisionSearch') { return $true }
  return $false
}

function Convert-JsonArray([string]$Text) {
  $items = @()
  if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
  try {
    $parsed = $Text | ConvertFrom-Json
    foreach ($item in $parsed) { $items += $item }
  } catch {}
  return @($items)
}

function Compare-Needles([string]$Haystack, [object[]]$MustContain, [object[]]$MustNotContain) {
  $missing = @()
  $matched = @()
  $forbidden = @()
  foreach ($needle in $MustContain) {
    if ([string]::IsNullOrWhiteSpace([string]$needle)) { continue }
    if ($Haystack.Contains([string]$needle)) { $matched += [string]$needle } else { $missing += [string]$needle }
  }
  foreach ($needle in $MustNotContain) {
    if ([string]::IsNullOrWhiteSpace([string]$needle)) { continue }
    if ($Haystack.Contains([string]$needle)) { $forbidden += [string]$needle }
  }
  return [pscustomobject]@{ matched = @($matched); missing = @($missing); forbidden = @($forbidden); ok = ($missing.Count -eq 0 -and $forbidden.Count -eq 0) }
}

function Invoke-StaticCase($Case) {
  $haystack = ''
  $missingSources = @()
  $invalidSources = @()
  foreach ($source in Get-ArrayProperty $Case 'sources') {
    $path = [System.IO.Path]::GetFullPath((Join-Path $Root ([string]$source)))
    if ($path.Equals($TestsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      $invalidSources += [string]$source
      continue
    }
    if (Test-Path $path) {
      $haystack += "`n" + (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
    } else {
      $missingSources += [string]$source
    }
  }
  $needleResult = Compare-Needles $haystack (Get-ArrayProperty $Case 'mustContain') (Get-ArrayProperty $Case 'mustNotContain')
  return [pscustomobject]@{
    ok = ($needleResult.ok -and $missingSources.Count -eq 0 -and $invalidSources.Count -eq 0)
    resultCount = 1
    maxConfidence = 1.0
    matched = @($needleResult.matched)
    missing = @($needleResult.missing)
    forbidden = @($needleResult.forbidden)
    missingSources = @($missingSources)
    invalidSources = @($invalidSources)
    exitCode = 0
  }
}

function Invoke-RecallCase($Case) {
  $query = Get-StringProperty $Case 'query' (Get-StringProperty $Case 'question')
  $topK = Get-IntProperty $Case 'topK' 3
  $maxTokens = Get-IntProperty $Case 'maxTokens' 1200
  $layer = Get-StringProperty $Case 'layer'
  if (-not [string]::IsNullOrWhiteSpace($layer)) {
    $output = (& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query $query -TopK $topK -MaxTokens $maxTokens -Layer $layer -Json) -join "`n"
  } else {
    $output = (& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query $query -TopK $topK -MaxTokens $maxTokens -Json) -join "`n"
  }
  $exitCode = $LASTEXITCODE
  $items = @(Convert-JsonArray $output)
  $jsonText = if ($items.Count -gt 0) { ($items | ConvertTo-Json -Depth 8 -Compress) } else { $output }
  $needleResult = Compare-Needles $jsonText (Get-ArrayProperty $Case 'mustContain') (Get-ArrayProperty $Case 'mustNotContain')
  $firstText = if ($items.Count -gt 0) { ($items[0] | ConvertTo-Json -Depth 8 -Compress) } else { '' }
  $firstNeedleResult = Compare-Needles $firstText (Get-ArrayProperty $Case 'firstMustContain') (Get-ArrayProperty $Case 'firstMustNotContain')
  $minResults = Get-IntProperty $Case 'minResults' 0
  $maxResults = Get-IntProperty $Case 'maxResults' -1
  $minConfidence = Get-DoubleProperty $Case 'minConfidence' 0
  $maxConfidence = 0.0
  foreach ($item in $items) {
    if ($null -ne $item.PSObject.Properties['confidence']) {
      $maxConfidence = [Math]::Max($maxConfidence, [double]$item.confidence)
    }
  }
  return [pscustomobject]@{
    ok = ($exitCode -eq 0 -and $needleResult.ok -and $firstNeedleResult.ok -and $items.Count -ge $minResults -and ($maxResults -lt 0 -or $items.Count -le $maxResults) -and $maxConfidence -ge $minConfidence)
    resultCount = $items.Count
    maxConfidence = [Math]::Round($maxConfidence, 4)
    matched = @($needleResult.matched)
    missing = @($needleResult.missing)
    forbidden = @($needleResult.forbidden)
    firstMatched = @($firstNeedleResult.matched)
    firstMissing = @($firstNeedleResult.missing)
    firstForbidden = @($firstNeedleResult.forbidden)
    missingSources = @()
    invalidSources = @()
    exitCode = $exitCode
  }
}

function Invoke-DecisionCase($Case) {
  $query = Get-StringProperty $Case 'query' (Get-StringProperty $Case 'question')
  $key = Get-StringProperty $Case 'key'
  $relation = Get-StringProperty $Case 'relation'
  $topK = Get-IntProperty $Case 'topK' 3
  $maxTokens = Get-IntProperty $Case 'maxTokens' 1200
  $status = Get-StringProperty $Case 'status'
  $adrOnly = ($Case.PSObject.Properties['adrOnly'] -and $Case.adrOnly -eq $true)
  $currentOnly = ($Case.PSObject.Properties['currentOnly'] -and $Case.currentOnly -eq $true)
  $params = @{ TopK=$topK; MaxTokens=$maxTokens; Json=$true }
  if (-not [string]::IsNullOrWhiteSpace($key)) { $params.Key = $key } else { $params.Query = $query }
  if (-not [string]::IsNullOrWhiteSpace($relation)) { $params.Relation = $relation }
  if (-not [string]::IsNullOrWhiteSpace($status)) { $params.Status = $status }
  if ($adrOnly) { $params.AdrOnly = $true }
  if ($currentOnly) { $params.CurrentOnly = $true }
  $output = (& (Join-Path $PSScriptRoot 'decision-search.ps1') @params) -join "`n"
  $exitCode = $LASTEXITCODE
  $items = @(Convert-JsonArray $output)
  $jsonText = if ($items.Count -gt 0) { ($items | ConvertTo-Json -Depth 8 -Compress) } else { $output }
  $needleResult = Compare-Needles $jsonText (Get-ArrayProperty $Case 'mustContain') (Get-ArrayProperty $Case 'mustNotContain')
  $minResults = Get-IntProperty $Case 'minResults' 0
  return [pscustomobject]@{
    ok = ($exitCode -eq 0 -and $needleResult.ok -and $items.Count -ge $minResults)
    resultCount = $items.Count
    maxConfidence = 0.0
    matched = @($needleResult.matched)
    missing = @($needleResult.missing)
    forbidden = @($needleResult.forbidden)
    missingSources = @()
    invalidSources = @()
    exitCode = $exitCode
  }
}

$caseResults = @()
foreach ($case in $tests) {
  $caseMode = Get-StringProperty $case 'mode' 'staticSources'
  if (-not (Test-ModeEnabled $caseMode)) { continue }
  $id = Get-StringProperty $case 'id' (Get-StringProperty $case 'question')
  $optional = ($case.PSObject.Properties['optional'] -and $case.optional -eq $true)
  $result = switch ($caseMode) {
    'recallSearch' { Invoke-RecallCase $case }
    'decisionSearch' { Invoke-DecisionCase $case }
    default { Invoke-StaticCase $case }
  }
  $status = if ($result.ok) { 'passed' } elseif ($optional) { 'skipped' } else { 'failed' }
  $caseResults += [pscustomobject]@{
    id = $id
    question = Get-StringProperty $case 'question'
    mode = $caseMode
    status = $status
    ok = ($status -ne 'failed')
    optional = $optional
    resultCount = $result.resultCount
    maxConfidence = $result.maxConfidence
    matched = @($result.matched)
    missing = @($result.missing)
    forbidden = @($result.forbidden)
    firstMatched = @($result.firstMatched)
    firstMissing = @($result.firstMissing)
    firstForbidden = @($result.firstForbidden)
    missingSources = @($result.missingSources)
    invalidSources = @($result.invalidSources)
    exitCode = $result.exitCode
    tags = @(Get-ArrayProperty $case 'tags')
  }
}

$failed = @($caseResults | Where-Object { $_.status -eq 'failed' }).Count
$passed = @($caseResults | Where-Object { $_.status -eq 'passed' }).Count
$skipped = @($caseResults | Where-Object { $_.status -eq 'skipped' }).Count
$runnable = [Math]::Max($caseResults.Count - $skipped, 1)
$report = [pscustomobject]@{
  ok = ($failed -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  version = $manifest.version
  suite = 'memory-eval'
  testsPath = $TestsPath
  mode = $Mode
  total = $caseResults.Count
  passed = $passed
  failed = $failed
  skipped = $skipped
  passRate = [Math]::Round($passed / $runnable, 4)
  metrics = [pscustomobject]@{
    maxConfidence = if ($caseResults.Count -gt 0) { [Math]::Round((@($caseResults | Measure-Object -Property maxConfidence -Maximum).Maximum), 4) } else { 0 }
    totalResults = if ($caseResults.Count -gt 0) { (@($caseResults | Measure-Object -Property resultCount -Sum).Sum) } else { 0 }
  }
  cases = @($caseResults)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 10
} else {
  Write-Host "MEMORY_EVAL ok=$($report.ok) total=$($report.total) passed=$($report.passed) failed=$($report.failed) skipped=$($report.skipped) passRate=$($report.passRate)"
  foreach ($caseResult in $caseResults) {
    Write-Host "CASE id=$($caseResult.id) status=$($caseResult.status) mode=$($caseResult.mode) results=$($caseResult.resultCount) confidence=$($caseResult.maxConfidence)"
  }
}

if ($report.ok) { exit 0 }
exit 1
