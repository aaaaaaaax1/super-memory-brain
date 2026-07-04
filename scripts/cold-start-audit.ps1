param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statusPath = Join-Path $workspace 'last-cold-start-audit.json'

function Invoke-JsonTool([string]$ScriptName, [scriptblock]$Call) {
  $output = @()
  try {
    $output = @(& $Call 6>$null 2>&1)
    $rawText = (@($output | ForEach-Object { [string]$_ }) -join "`n")
    $cleanText = $rawText -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
    $start = $cleanText.IndexOf('{')
    $end = $cleanText.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) { return [pscustomobject]@{ parsed=$false; ok=$false; error="No JSON object output from $ScriptName"; value=$null; raw=@($output) } }
    $jsonText = $cleanText.Substring($start, $end - $start + 1)
    $parsed = $jsonText | ConvertFrom-Json
    $parsedOk = if ($null -ne $parsed.PSObject.Properties['ok']) { [bool]$parsed.ok } else { $true }
    return [pscustomobject]@{ parsed=$true; ok=$parsedOk; error=''; value=$parsed; raw=@($output) }
  } catch {
    return [pscustomobject]@{ parsed=$false; ok=$false; error=$_.Exception.Message; value=$null; raw=@($output) }
  }
}

function New-CaseResult([string]$Name, [string]$Prompt, [string]$Kind, [bool]$Ok, [string]$Reason, [object]$Observed) {
  return [pscustomobject]@{
    name = $Name
    prompt = $Prompt
    kind = $Kind
    ok = $Ok
    reason = $Reason
    observed = $Observed
  }
}

function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
$zhContinue = U @(0x7EE7,0x7EED)
$zhBrain = U @(0x8111,0x5B50)
$zhBigBrain = U @(0x5927,0x8111)
$zhThis = U @(0x8FD9,0x4E2A)
$zhModel = U @(0x578B,0x53F7)
$zhHow = U @(0x600E,0x4E48,0x6837)
$incidentalG1Prompt = $zhThis + ' G1 ' + $zhModel + $zhHow

$cases = @()
$plainContinue = Invoke-JsonTool 'session-restore.ps1' { & (Join-Path $PSScriptRoot 'session-restore.ps1') -Query 'continue' -Json }
$cases += New-CaseResult 'plain_continue_no_recall_en' 'continue' 'session-restore' ($plainContinue.parsed -and $plainContinue.value.recallTriggered -eq $false -and @($plainContinue.value.evidenceCards).Count -eq 0) 'plain continue must not trigger recall or evidence cards' $plainContinue.value

$plainContinueZh = Invoke-JsonTool 'session-restore.ps1' { & (Join-Path $PSScriptRoot 'session-restore.ps1') -Query $zhContinue -Json }
$cases += New-CaseResult 'plain_continue_no_recall_zh' $zhContinue 'session-restore' ($plainContinueZh.parsed -and $plainContinueZh.value.recallTriggered -eq $false -and @($plainContinueZh.value.evidenceCards).Count -eq 0) 'plain Chinese continue must not trigger recall or evidence cards' $plainContinueZh.value

$smartContinue = Invoke-JsonTool 'smart-next.ps1' { & (Join-Path $PSScriptRoot 'smart-next.ps1') $zhContinue -Json }
$cases += New-CaseResult 'smart_next_continue_light' $zhContinue 'smart-next' ($smartContinue.parsed -and $smartContinue.value.intent -eq 'continue' -and $smartContinue.value.dashboardMode -eq 'Light' -and @($smartContinue.value.dispatchRecommendations).Count -eq 0) 'smart-next continue must use Light dashboard and no dispatch recommendations' $smartContinue.value

$dashboardLight = Invoke-JsonTool 'super-brain-dashboard.ps1' { & (Join-Path $PSScriptRoot 'super-brain-dashboard.ps1') -Mode Light -Json }
$cases += New-CaseResult 'dashboard_light_no_full_modules' 'dashboard light' 'dashboard' ($dashboardLight.parsed -and $dashboardLight.value.mode -eq 'Light' -and $null -eq $dashboardLight.value.memoryRegression.ok -and $null -eq $dashboardLight.value.privacy.ok -and $null -eq $dashboardLight.value.reviewGate.ok) 'Light dashboard must not wake memory regression, privacy, or team review gate' $dashboardLight.value

$autoCheck = Invoke-JsonTool 'auto-check.ps1' { & (Join-Path $PSScriptRoot 'auto-check.ps1') -MaxAgeMinutes 0 -Json }
$cases += New-CaseResult 'auto_check_stale_no_full_verify' 'auto-check stale' 'auto-check' ($autoCheck.parsed -and $autoCheck.value.verifySuggested -eq $true -and $autoCheck.value.note -like '*Default mode does not run full verify*') 'stale auto-check must suggest verify instead of running full verify by default' $autoCheck.value

$triggerSimulation = Invoke-JsonTool 'trigger-simulation.ps1' { & (Join-Path $PSScriptRoot 'trigger-simulation.ps1') -Json }
$negativeFailures = @()
if ($triggerSimulation.parsed) {
  $negativeFailures = @($triggerSimulation.value.results | Where-Object { ([string]$_.kind -like '*negative*') -and $_.ok -ne $true })
}
$cases += New-CaseResult 'trigger_negative_wake_words' ($zhBigBrain + '/' + $zhBrain + '/G1 incidental cases') 'trigger-simulation' ($triggerSimulation.parsed -and @($negativeFailures).Count -eq 0) 'negative wake-word scenarios must not trigger Super Brain/G1' ([pscustomobject]@{ failedNegativeCount=@($negativeFailures).Count; failedNegativeCases=@($negativeFailures) })

$intentCasual = Invoke-JsonTool 'intent-router.ps1' { & (Join-Path $PSScriptRoot 'intent-router.ps1') $incidentalG1Prompt -Json }
$cases += New-CaseResult 'intent_incidental_g1_not_team_or_memory' $incidentalG1Prompt 'intent-router' ($intentCasual.parsed -and $intentCasual.value.intent -notin @('team_or_review','memory_recall')) 'incidental G1 product mention must not route to team or memory recall' $intentCasual.value

$failed = @($cases | Where-Object { $_.ok -ne $true })
$result = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = (Get-SuperBrainManifest $Root).version
  total = $cases.Count
  failed = $failed.Count
  cases = @($cases)
  nextAction = if ($failed.Count -eq 0) { 'Cold-start audit passed: keep ordinary paths light.' } else { 'Fix failed cold-start audit cases before declaring output discipline stable.' }
}
Write-JsonUtf8NoBom $statusPath $result 12

if ($Json) {
  $result | ConvertTo-Json -Depth 12
} else {
  Write-Host "COLD_START_AUDIT ok=$($result.ok) total=$($result.total) failed=$($result.failed) status=$statusPath"
  foreach ($case in @($cases)) { Write-Host "COLD_START_CASE name=$($case.name) ok=$($case.ok) reason=$($case.reason)" }
}
if (-not $result.ok) { exit 1 }
exit 0
