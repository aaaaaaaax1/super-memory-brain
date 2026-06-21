param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'

function Invoke-JsonTool([string]$ScriptName, [string[]]$ToolArgs = @()) {
  $path = Join-Path $PSScriptRoot $ScriptName
  if (-not (Test-Path $path)) {
    return [pscustomobject]@{ ok=$false; script=$ScriptName; exitCode=1; data=$null; error='missing script' }
  }
  try {
    if (@($ToolArgs) -contains '-Json') {
      $output = @(& $path -Json 6>$null)
    } else {
      $output = @(& $path @ToolArgs 6>$null)
    }
    $exitCode = $LASTEXITCODE
    $jsonStart = -1
    for ($index = 0; $index -lt $output.Count; $index++) {
      if ([string]$output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
    }
    if ($jsonStart -lt 0) {
      return [pscustomobject]@{ ok=$false; script=$ScriptName; exitCode=$exitCode; data=$null; error='no json output' }
    }
    $data = ((@($output[$jsonStart..($output.Count - 1)]) -join "`n") | ConvertFrom-Json)
    return [pscustomobject]@{ ok=($exitCode -eq 0); script=$ScriptName; exitCode=$exitCode; data=$data; error=$null }
  } catch {
    return [pscustomobject]@{ ok=$false; script=$ScriptName; exitCode=1; data=$null; error=$_.Exception.Message }
  }
}

function Invoke-TextTool([string]$ScriptName, [string[]]$ToolArgs = @()) {
  $path = Join-Path $PSScriptRoot $ScriptName
  if (-not (Test-Path $path)) { return [pscustomobject]@{ ok=$false; script=$ScriptName; exitCode=1; output=@(); error='missing script' } }
  try {
    $output = @(& $path @ToolArgs)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ ok=($exitCode -eq 0); script=$ScriptName; exitCode=$exitCode; output=@($output); error=$null }
  } catch {
    return [pscustomobject]@{ ok=$false; script=$ScriptName; exitCode=1; output=@(); error=$_.Exception.Message }
  }
}

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Add-Advice([object[]]$List, [string]$Priority, [string]$Code, [string]$Title, [string]$Action, [string]$Reason, [string]$Evidence = '') {
  $List += [pscustomobject]@{
    priority = $Priority
    code = $Code
    title = $Title
    action = $Action
    reason = $Reason
    evidence = $Evidence
  }
  return @($List)
}

$doctor = Invoke-JsonTool 'doctor.ps1' @('-Json')
$quality = Invoke-JsonTool 'memory-quality-fixer.ps1' @('-Json')
$eval = Invoke-JsonTool 'memory-eval.ps1' @('-Json')
$retention = Invoke-TextTool 'backup-retention.ps1' @()
$lastCi = Read-WorkspaceJson 'last-ci.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'

$advice = @()
$risks = @()

if (-not $doctor.ok -or $null -eq $doctor.data -or $doctor.data.ok -ne $true) {
  $advice = Add-Advice $advice 'high' 'doctor_not_ok' 'Run doctor diagnostics first' 'scripts\doctor.ps1 -Json' 'The aggregate health check is unavailable or unhealthy.' 'doctor.ps1'
} elseif ($doctor.data.riskSummary.total -gt 0) {
  foreach ($risk in @($doctor.data.risks | Select-Object -First 5)) {
    $priority = if ($risk.severity -eq 'high') { 'high' } elseif ($risk.severity -eq 'medium') { 'medium' } else { 'low' }
    $advice = Add-Advice $advice $priority $risk.code 'Resolve doctor risk' 'Inspect the risk source and fix the reported condition.' $risk.message $risk.source
  }
}

if ($quality.ok -and $quality.data) {
  $tooLong = @($quality.data.actions | Where-Object { $_.type -eq 'too_long' })
  $untagged = @($quality.data.actions | Where-Object { $_.type -eq 'untagged' })
  $malformed = @($quality.data.actions | Where-Object { $_.type -eq 'malformed_decision_particle' })
  if ($tooLong.Count -gt 0) {
    $advice = Add-Advice $advice 'high' 'compress_long_memory' "Compress $($tooLong.Count) long memory entries" 'scripts\memory-quality-fixer.ps1 -ShowDetails -Json, then rewrite long entries through governed memory tools after review.' 'Long memory entries increase prompt cost and reduce recall precision.' "memory-quality-fixer:too_long=$($tooLong.Count)"
  }
  if ($untagged.Count -gt 0) {
    $advice = Add-Advice $advice 'medium' 'tag_untagged_memory' "Tag $($untagged.Count) untagged memory entries" 'Review required tags and migrate vague entries to structured notes.' 'Untagged memory is harder to route by layer.' "memory-quality-fixer:untagged=$($untagged.Count)"
  }
  if ($malformed.Count -gt 0) {
    $advice = Add-Advice $advice 'high' 'repair_decision_particles' "Repair $($malformed.Count) malformed decision particles" 'Rewrite malformed decision particles with timestamp, key, title, decision, evidence, and tags.' 'Malformed decisions weaken auditability.' "memory-quality-fixer:malformed=$($malformed.Count)"
  }
} else {
  $advice = Add-Advice $advice 'medium' 'quality_check_unavailable' 'Run memory quality planner' 'scripts\memory-quality-fixer.ps1 -Json' 'The optimization advisor could not read quality findings.' 'memory-quality-fixer.ps1'
}

if (-not $eval.ok -or $null -eq $eval.data -or $eval.data.ok -ne $true) {
  $advice = Add-Advice $advice 'high' 'memory_eval_failed' 'Fix memory eval failures' 'scripts\memory-eval.ps1 -Json' 'Recall and decision quality tests should pass before release or major routing changes.' 'memory-eval.ps1'
}

if ($null -eq $lastCi) {
  $advice = Add-Advice $advice 'medium' 'ci_missing' 'Run local CI before release' 'scripts\ci.ps1' 'No durable last-ci.json was found.' 'memory/workspace/last-ci.json'
} elseif ($lastCi.ok -ne $true) {
  $advice = Add-Advice $advice 'medium' 'ci_not_ok' 'Fix latest CI result' 'scripts\ci.ps1' 'The latest durable CI result is not OK.' 'memory/workspace/last-ci.json'
}

if ($null -eq $lastHotRefresh) {
  $advice = Add-Advice $advice 'medium' 'hot_refresh_missing' 'Hot-refresh installed skills after brain changes' 'scripts\hot-refresh-skills.ps1 -AllKnown' 'No durable hot-refresh result was found.' 'memory/workspace/last-hot-refresh.json'
} elseif ($lastHotRefresh.ok -ne $true) {
  $advice = Add-Advice $advice 'medium' 'hot_refresh_not_ok' 'Refresh installed skill copies' 'scripts\hot-refresh-skills.ps1 -AllKnown' 'The latest hot-refresh result is not OK.' 'memory/workspace/last-hot-refresh.json'
}

if ($advice.Count -eq 0) {
  $advice = Add-Advice $advice 'low' 'no_action_required' 'No immediate optimization required' 'Keep using doctor.ps1, memory-eval.ps1, and maintain.ps1 for routine checks.' 'All checked health, quality, and eval signals are currently OK.' 'optimize-advisor.ps1'
}

$priorityRank = @{ high=0; medium=1; low=2 }
$advice = @($advice | Sort-Object @{ Expression = { $priorityRank[$_.priority] } }, code)
$top = @($advice | Select-Object -First 3)

$result = [pscustomobject]@{
  ok = (($doctor.ok -and ($doctor.data.ok -eq $true)) -and ($eval.ok -and ($eval.data.ok -eq $true)))
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  version = if ($doctor.data) { $doctor.data.version } else { 'UNKNOWN' }
  priority = if ($top.Count -gt 0) { $top[0].code } else { 'none' }
  adviceCount = $advice.Count
  topAdvice = @($top)
  advice = @($advice)
  signals = [pscustomobject]@{
    doctorOk = ($doctor.ok -and $doctor.data.ok -eq $true)
    doctorRisks = if ($doctor.data) { [int]$doctor.data.riskSummary.total } else { $null }
    memoryQualityActions = if ($quality.data) { [int]$quality.data.actionCount } else { $null }
    memoryEvalOk = ($eval.ok -and $eval.data.ok -eq $true)
    memoryEvalPassed = if ($eval.data) { "$($eval.data.passed)/$($eval.data.total)" } else { $null }
    lastCiOk = if ($lastCi) { $lastCi.ok } else { $null }
    lastHotRefreshOk = if ($lastHotRefresh) { $lastHotRefresh.ok } else { $null }
    backupRetentionOk = $retention.ok
  }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "OPTIMIZE_ADVISOR ok=$($result.ok) version=$($result.version) priority=$($result.priority) advice=$($result.adviceCount) doctorRisks=$($result.signals.doctorRisks) qualityActions=$($result.signals.memoryQualityActions) eval=$($result.signals.memoryEvalPassed)"
  foreach ($item in $top) {
    Write-Host "OPTIMIZE priority=$($item.priority) code=$($item.code) title=$($item.title) action=$($item.action)"
  }
  if ($result.ok) { Write-Host 'OPTIMIZE_ADVISOR_OK' } else { Write-Host 'OPTIMIZE_ADVISOR_WARN' }
}

if ($result.ok) { exit 0 }
exit 1
